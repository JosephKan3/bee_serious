--[[
  Bee Keeper Manager
  -------------------
  Orchestrates Forestry bee breeding via OpenComputers' UpgradeBeekeeper
  (component "beekeeper") instead of a fixed Transposer network. An Agent
  (Robot or Drone) carrying this upgrade interacts with whichever apiary is
  directly next to it, side-relative -- no wiring, no transposers.

  Everything below was confirmed by reading the actual mod source
  (li.cil.oc.integration.forestry.*), not guessed:

    - swapQueen(side)/swapDrone(side): swap whatever's in your CURRENTLY
      SELECTED inventory slot with the apiary's queen/drone slot. This is
      how you both load a fresh pair AND harvest a spent queen -- whatever
      was sitting there comes back into your selected slot.
    - getBeeProgress(side)/canWork(side): apiary status, side-relative.
    - analyze(honeySlot): analyzes the bee in your selected slot, consuming
      1 honey/honeydew from the given slot.
    - None of these require the apiary to be a registered OC component --
      UpgradeBeekeeperUtil queries the world position at `side` directly.
    - inventory_controller's slot-peek/suck/drop methods (getStackInSlot,
      getStackInInternalSlot, suckFromSlot) are IDENTICAL between the Robot
      and Drone variants (confirmed in UpgradeInventoryController.scala) --
      this manager doesn't care which host it's running on for those.
    - A bee's genome, read via inventory_controller (getStackInSlot /
      getStackInInternalSlot), comes back as stack.individual.{active,
      inactive,isAnalyzed,...} (matching beeManager.lua's established
      convention). bee_housing.getQueen()/getDrone() return the individual
      itself, UNWRAPPED (no .individual nesting) -- see readIndividual()
      below, which handles both shapes.
    - bee_housing (getBeeParents, getQueen, getDrone, canBreed, ...) is
      exposed by ANY apiary block, not a separate dedicated block -- but
      it's only reachable if OC's normal adjacency-component visibility
      extends to a moving Agent the same way it does a stationary
      Computer+Adapter. NOT independently confirmed for a moving host --
      guarded with pcall and a config-supplied fallback mutation table
      (see M.lookupMutationParents).

  ASSUMED HARDWARE (flag if wrong, easy to adjust):
    - Agent (Robot or Drone) with "beekeeper" AND "inventory_controller"
      upgrades installed.
    - Honey/honeydew stock sitting in a known slot (config.honeySlot).
    - A handful of "working slots" in the agent's own inventory used as the
      live candidate-bee pool (config.workingSlots) -- this replaces
      beeManager.lua's big storage-chest catalog; there's no room for that
      here, so the pool is just whatever fits in cargo at once.

  MOVEMENT: sites are (x,z) positions at one fixed Y level (see
  bee_keeper_nav.lua) -- the drone flies DIRECTLY above each apiary and
  always interacts via sides.down, never side-relative horizontal offsets.
  Site positions come from bee_keeper_setup.lua's area scan, persisted to
  disk; see M.loadSites for how those get merged with the mode/
  targetSpecies assignments you configure by hand.

  THREE MODES (per site, set via config.siteOverrides[name].mode, default
  "traitmax" for anything not overridden):
    "traitmax" -- no species target. Get as close to a max-trait bee as
                  possible from whatever's on hand; species is untracked.
                  This is the fallback/default: even if parents have no
                  good alleles at all, it always makes the locally best
                  available choice each cycle (bee_breeding.lua never
                  requires reaching the target to make progress).
    "species"  -- you already hold at least one specimen (any quality) of
                  targetSpecies. Purify toward pure-species + max traits
                  simultaneously by tracking species as just one more
                  trait (bee_trait_config.lua/bee_breeding.lua's
                  species-as-a-trait support).
    "mutation" -- you do NOT yet hold targetSpecies. Look up its mutation
                  recipe (candidate parent-species pairs + base chance),
                  match against species you actually hold, load the best
                  satisfiable pair, and keep re-attempting (mutation is
                  probabilistic per successful mating in Forestry). Once
                  any specimen of targetSpecies shows up in the harvest,
                  the site's mode is expected to be switched to "species"
                  (see M.checkMutationSuccess) so it takes over from there.
--]]

local BB = require("bee_breeding")
local Cfg = require("bee_trait_config")
local Nav = require("bee_keeper_nav")
local Status = require("bee_keeper_status")

local M = {}
M.Nav = Nav

-- ============================================================
-- Hardware access (lazy -- resolved on first use, not at require time, so
-- this module can be `require`d for testing outside Minecraft with a
-- mocked "component"/"sides" pair of modules pre-seeded into
-- package.loaded).
-- ============================================================

local function component() return require("component") end
local function sides() return require("sides") end

local function beekeeper() return component().beekeeper end
local function invCtrl() return component().inventory_controller end
local function agent()
  local c = component()
  if c.isAvailable("robot") then return c.robot end
  return c.drone
end

-- ============================================================
-- Genome reading
-- ============================================================

-- A bee's genome comes back two different shapes depending on API used:
--   - inventory_controller stack descriptions nest it under .individual
--   - bee_housing.getQueen()/getDrone() return the individual UNWRAPPED
-- This normalizes both into the individual table itself, or nil if the
-- given value isn't an analyzed bee.
local function readIndividual(raw)
  if not raw then return nil end
  local individual = raw.individual or raw
  if not individual.isAnalyzed then return nil end
  if not individual.active or not individual.inactive then return nil end
  return individual
end
M.readIndividual = readIndividual

-- Peek at a slot in the agent's own inventory (does NOT consume/move
-- anything). Returns the individual table, or nil if empty/not a bee/not
-- analyzed.
function M.readOwnSlot(slot)
  local stack = invCtrl().getStackInInternalSlot(slot)
  return readIndividual(stack)
end

-- Peek at a slot of the inventory on the given side (e.g. an apiary's
-- queen slot = 1, drone slot = 2). Does NOT consume/move anything.
function M.readSideSlot(side, slot)
  local stack = invCtrl().getStackInSlot(side, slot)
  return readIndividual(stack)
end

-- Lists the agent's own occupied cargo slots as { {slot=N, stack=rawStack}, ... }
-- -- for bee_keeper_ui.lua's cargo panel. Unlike readOwnSlot, returns the
-- RAW stack (not just .individual), since the UI wants to show non-bee
-- items (honey) too, not just analyzed bees. Always safe to call: reading
-- your own inventory has no position constraint, unlike an external one
-- (see M.listStorage in bee_keeper_local_sim_run.lua's real-hardware note).
function M.listCargo(config)
  local list = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack then table.insert(list, { slot = slot, stack = stack }) end
  end
  return list
end

-- Fraction (0..1) of tracked loci already fixed to GG (homozygous good) --
-- i.e. how close this bee is to fully purebred-perfect. 1.0 means every
-- tracked trait is locked in and BB.isPurebred would return true.
function M.purityOf(traitList, genotype)
  if #traitList == 0 then return 0 end
  local fixed = 0
  for _, trait in ipairs(traitList) do
    if BB.traitState(genotype, trait) == "GG" then fixed = fixed + 1 end
  end
  return fixed / #traitList
end

-- Build a bee_breeding.lua-compatible {id, genotype} from something an
-- inventory read/peek returned, or nil if it's not a usable analyzed bee.
local function toBreedingBee(id, individual, traitList, targetSpecies)
  if not individual then return nil end
  local genotype = Cfg.normalizeGenotype(traitList, individual.active, individual.inactive, targetSpecies)
  return { id = id, genotype = genotype, _individual = individual }
end
M.toBreedingBee = toBreedingBee

-- ============================================================
-- Trait list per mode
-- ============================================================

-- traitmax: quality traits only, species untracked/ignored entirely.
-- species: quality traits + species (targetSpecies decides "good" there).
function M.traitListFor(mode)
  local traits = Cfg.activeTraits()
  if mode == "species" or mode == "mutation" then
    table.insert(traits, "species")
  end
  return traits
end

-- ============================================================
-- Movement: sites are (x,z) at the fixed flight altitude; always
-- interact via sides.down once positioned directly above.
-- ============================================================

local function gotoSite(site)
  return Nav.gotoXZ(site.x, site.z)
end
M.gotoSite = gotoSite

-- ============================================================
-- Core per-site cycle: traitmax / species modes
-- (identical machinery -- they differ only in traitListFor's output and
-- whether targetSpecies is set)
-- ============================================================

-- Matched by item name, case-insensitively, since Forestry's own
-- princess/queen items both qualify (a queen is just a mated princess).
local function isPrincessOrQueenStack(stack)
  if not stack or not stack.name then return false end
  local lower = stack.name:lower()
  return lower:find("princess") ~= nil or lower:find("queen") ~= nil
end

-- Gathers usable candidate DRONES from the working slots (analyzed bees
-- only -- unanalyzed ones are queued for analysis instead, see
-- M.analyzeWorkingSlots). Explicitly excludes princess/queen items --
-- without this, a harvested princess sitting in cargo (e.g. waiting to be
-- re-seeded via M.runQualitySite's findPrincessCandidate below) gets
-- scored and treated as an ordinary breeding drone by
-- bee_breeding.planGeneration, and if she isn't picked as the "best
-- drone" this cycle, ends up in plan.toDiscard and gets flown to
-- storage/trash right along with actually-unwanted drones. This is
-- exactly what real hardware hit: a princess got stored instead of
-- staying available to re-seed her own apiary.
local function gatherCandidateDrones(config, traitList, targetSpecies)
  local pool = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local individual = readIndividual(stack)
    if individual and not isPrincessOrQueenStack(stack) then
      local bee = toBreedingBee("slot" .. slot, individual, traitList, targetSpecies)
      bee._slot = slot
      table.insert(pool, bee)
    end
  end
  return pool
end

-- Finds an analyzed princess/queen sitting in the agent's own cargo,
-- for seeding an apiary whose queen slot has gone empty (see the
-- no-princess branch in M.runQualitySite below for why this is needed at
-- all). Returns the working slot number, or nil if cargo has none.
local function findPrincessCandidate(config)
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if isPrincessOrQueenStack(stack) and readIndividual(stack) then
      return slot
    end
  end
  return nil
end

-- swapDrone/swapQueen hand over the ENTIRE stack sitting in the currently
-- selected slot, not one item -- fine for a princess/queen (Forestry
-- never stacks those), but a drone slot can now legitimately hold
-- several genetically identical drones at once since harvestSite/
-- findStackingSlot started merging matches together. Splitting the
-- stack was the missing step: without this, loading "one drone" into an
-- apiary actually handed over the whole stack, wasting every extra
-- drone in it (the apiary only ever consumes one per mating). Returns
-- the slot now holding exactly ONE item (either the original slot
-- unchanged, or a freshly split-off single-item slot), or nil if the
-- stack needs splitting but no empty working slot is free to split into.
local function ensureSingleItemSlot(config, slot)
  local stack = invCtrl().getStackInInternalSlot(slot)
  if not stack or (stack.size or 1) <= 1 then return slot end

  for _, candidate in ipairs(config.workingSlots) do
    if candidate ~= slot and invCtrl().getStackInInternalSlot(candidate) == nil then
      agent().select(slot)
      if agent().transferTo(candidate, 1) then
        return candidate
      end
      return nil
    end
  end
  return nil
end

-- Runs one decision+action cycle for a "traitmax" or "species" site.
-- Returns a short status string for logging.
function M.runQualitySite(config, site)
  Status.setStep("Heading to " .. (site.name or "?") .. " (" .. site.mode .. ")")
  local ok, reason = gotoSite(site)
  if not ok then return "nav_failed:" .. tostring(reason) end

  local down = sides().down
  local traitList = M.traitListFor(site.mode)
  local targetSpecies = site.targetSpecies

  if beekeeper().canWork(down) then
    return string.format("working (%.0f%%)", beekeeper().getBeeProgress(down))
  end

  local princessIndividual = M.readSideSlot(down, 1)
  if not princessIndividual then
    -- The apiary's queen slot is empty. This isn't necessarily "never
    -- had one" -- a spent queen is fully CONSUMED by Forestry once she
    -- finishes breeding, and her replacement offspring princess lands in
    -- the product/output area (confirmed via probeInventoryBelow()), NOT
    -- back in the queen slot. Nothing else in this file ever re-seeds a
    -- princess for traitmax/species sites (only the mutation flow calls
    -- swapQueen), so without this, a site goes permanently idle the
    -- moment its queen runs out.
    local princessSlot = findPrincessCandidate(config)
    if not princessSlot then
      return "no_princess_at_site_or_in_cargo"
    end
    Status.setStep("Seeding princess into " .. (site.name or "?"))
    agent().select(princessSlot)
    if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
    -- Loading a drone against her happens next cycle, once she's readable
    -- back out of the apiary (this cycle already consumed the working
    -- slot she came from).
    return "seeded princess, will load drone next cycle"
  end

  Status.setStep("Evaluating drones for " .. (site.name or "?"))
  local princessBee = toBreedingBee("princess", princessIndividual, traitList, targetSpecies)

  -- Cache how close this apiary's princess is to purebred-perfect, for
  -- the dashboard. Stored on the site rather than passed around because
  -- an apiary's contents are a side-relative read -- only knowable while
  -- the drone is actually standing at it -- so this is a last-known
  -- value, refreshed each visit, not live telemetry.
  site.progress = M.purityOf(traitList, princessBee.genotype)
  local dronePool = gatherCandidateDrones(config, traitList, targetSpecies)
  if #dronePool == 0 then
    return "no_candidate_drones_in_working_slots"
  end

  local endgame = BB.isPhenotypicallyPerfect(traitList, princessBee.genotype)
  local plan = BB.planGeneration(traitList, princessBee.genotype, dronePool, {}, endgame,
    config.minCopies, Cfg.weights)

  if not plan.breedWith then
    return "no_viable_drone"
  end

  -- Discard drones the plan doesn't want, to make room. Default behavior:
  -- fly them to config.trashPos (permanently voided -- see M.dumpToTrash)
  -- if known, else config.storagePos (see M.dumpToStorage) -- trash is
  -- preferred when both are known, since a breeding program generates a
  -- steady stream of unwanted drones that would otherwise slowly fill up
  -- a finite storage chest. Override config.onDiscard to route elsewhere
  -- entirely (sampler/furnace/junk).
  local discardCount = 0
  for _, entry in ipairs(plan.toDiscard) do
    if entry.drone.id ~= plan.breedWith.id then
      discardCount = discardCount + 1
      if config.onDiscard then
        config.onDiscard(entry.drone)
      end
    end
  end
  if discardCount > 0 and not config.onDiscard and (config.trashPos or config.storagePos) then
    if config.trashPos then
      M.dumpToTrash(config, plan.toDiscard, plan.breedWith.id)
    else
      M.dumpToStorage(config, plan.toDiscard, plan.breedWith.id)
    end
    -- flew away to drop off discards -- come back before finishing the
    -- swap below, or it lands on the storage/trash position instead of
    -- the apiary (caught by the local simulator: swapDrone would fail
    -- there since there's no apiary at that position).
    local backOk, backReason = gotoSite(site)
    if not backOk then return "nav_failed_returning_from_discard:" .. tostring(backReason) end
  end

  Status.setStep("Loading drone into " .. (site.name or "?"))
  local droneSlot = ensureSingleItemSlot(config, plan.breedWith._slot)
  if not droneSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(droneSlot)
  local swapped = beekeeper().swapDrone(down)
  if not swapped then return "swap_drone_failed" end

  return string.format("loaded drone (score %.1f)", plan.score)
end

-- ============================================================
-- Mutation mode
-- ============================================================

-- Query the live mutation graph for targetSpecies via any apiary's
-- bee_housing component. Falls back to config.mutationFallback[targetSpecies]
-- (same {allele1={name=..},allele2={name=..},chance=N} shape) if
-- bee_housing isn't reachable from a moving agent (unconfirmed -- see
-- header notes).
function M.lookupMutationParents(config, targetSpecies)
  local ok, result = pcall(function()
    return component().bee_housing.getBeeParents(targetSpecies)
  end)
  if ok and result then
    return result
  end
  return config.mutationFallback and config.mutationFallback[targetSpecies] or {}
end

-- Groups the agent's working-slot bees by species name (Cfg.speciesKey),
-- keeping a princess-capable and drone-capable list. Forestry doesn't
-- generally care which side (princess/drone) a species enters a mutation
-- from, so both roles are gathered per species.
local function groupBySpecies(config)
  local bySpecies = {}
  for _, slot in ipairs(config.workingSlots) do
    local individual = M.readOwnSlot(slot)
    if individual then
      local name = Cfg.speciesKey(individual.active.species)
      bySpecies[name] = bySpecies[name] or {}
      table.insert(bySpecies[name], { slot = slot, individual = individual })
    end
  end
  return bySpecies
end

-- Picks the best-scoring specimen for a species using the ACTIVE quality
-- traits (no species target -- we already know the species matches).
local function bestOfSpecies(candidates, traitList)
  local best, bestScore = nil, -math.huge
  for _, c in ipairs(candidates) do
    local score = 0
    for _, t in ipairs(traitList) do
      if BB.traitState(Cfg.normalizeGenotype({ t }, c.individual.active, c.individual.inactive), t) == "GG" then
        score = score + 1
      end
    end
    if score > bestScore then
      bestScore = score
      best = c
    end
  end
  return best
end

-- Finds the highest-chance mutation recipe for targetSpecies that's
-- actually satisfiable with species currently in the working slots (one
-- specimen of each required parent species). Returns
-- { princessSlot, droneSlot, chance } or nil if nothing's satisfiable yet
-- (in which case the two required species names are still worth logging).
function M.planMutation(config, targetSpecies, traitList)
  local recipes = M.lookupMutationParents(config, targetSpecies)
  local held = groupBySpecies(config)

  local best, bestChance = nil, -1
  local missingReport = nil

  for _, recipe in ipairs(recipes) do
    local nameA = Cfg.speciesKey(recipe.allele1)
    local nameB = Cfg.speciesKey(recipe.allele2)
    local haveA = held[nameA]
    local haveB = held[nameB]

    if haveA and haveB then
      if recipe.chance > bestChance then
        local princessPick = bestOfSpecies(haveA, traitList)
        local dronePick = bestOfSpecies(haveB, traitList)
        bestChance = recipe.chance
        best = { princessSlot = princessPick.slot, droneSlot = dronePick.slot, chance = recipe.chance,
                 princessSpecies = nameA, droneSpecies = nameB }
      end
    elseif not missingReport then
      missingReport = string.format("need one of '%s' and one of '%s' (%.0f%% base chance)",
        nameA, nameB, recipe.chance)
    end
  end

  return best, missingReport
end

-- Runs one decision+action cycle for a "mutation" site.
function M.runMutationSite(config, site)
  Status.setStep("Heading to " .. (site.name or "?") .. " (mutation)")
  local ok, reason = gotoSite(site)
  if not ok then return "nav_failed:" .. tostring(reason) end

  local down = sides().down
  if beekeeper().canWork(down) then
    return string.format("attempting (%.0f%%)", beekeeper().getBeeProgress(down))
  end

  -- Same last-known purity cache as runQualitySite (see the note there).
  -- A mutation site is often empty between attempts, in which case there
  -- is simply nothing to measure yet.
  local mutationTraits = M.traitListFor(site.mode)
  local sittingPrincess = M.readSideSlot(down, 1)
  if sittingPrincess then
    local sittingBee = toBreedingBee("princess", sittingPrincess, mutationTraits, site.targetSpecies)
    site.progress = M.purityOf(mutationTraits, sittingBee.genotype)
  end

  -- Once a mutation succeeds, some harvested offspring will be
  -- targetSpecies -- check the working slots for one before planning
  -- another attempt, so a lucky success isn't immediately overwritten.
  local traitList = mutationTraits
  for _, slot in ipairs(config.workingSlots) do
    local individual = M.readOwnSlot(slot)
    if individual and Cfg.speciesKey(individual.active.species) == site.targetSpecies then
      return "mutation_succeeded:switch_site_to_species_mode"
    end
  end

  local plan, missingReport = M.planMutation(config, site.targetSpecies, traitList)
  if not plan then
    return "waiting_on_parent_species:" .. (missingReport or "no_known_recipe")
  end

  Status.setStep(string.format("Attempting mutation at %s: %s x %s",
    site.name or "?", plan.princessSpecies, plan.droneSpecies))
  agent().select(plan.princessSlot)
  if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
  local droneSlot = ensureSingleItemSlot(config, plan.droneSlot)
  if not droneSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(droneSlot)
  if not beekeeper().swapDrone(down) then return "swap_drone_failed" end

  return string.format("attempting mutation %s x %s (%.0f%% base chance)",
    plan.princessSpecies, plan.droneSpecies, plan.chance)
end

-- ============================================================
-- Harvesting: pull an apiary's product slots into working slots
-- ============================================================

-- Tracks which sites have already had a full slot dump logged (see the
-- harvested==0 diagnostic below) so a persistently-empty apiary doesn't
-- flood the log every cycle.
local diagDumpedSites = {}

-- Whether two raw item stacks would actually merge in a real inventory
-- slot: same item name, and if it's an analyzed bee, an EXACT genotype
-- match (Forestry only stacks genetically identical drones -- princesses/
-- queens never stack at all regardless of genotype, but those are
-- already excluded from anything routed through here -- see
-- isPrincessOrQueenStack). Species is a nested table ({name=,uid=,...}),
-- not directly comparable with == , so it's matched by contents instead.
local function stacksMatch(a, b)
  if not a or not b or a.name ~= b.name then return false end
  local ai, bi = a.individual, b.individual
  if not ai and not bi then return true end
  if not (ai and bi) then return false end
  if ai.isAnalyzed ~= bi.isAnalyzed then return false end

  local function valuesEqual(x, y)
    if type(x) == "table" and type(y) == "table" then
      return x.name == y.name and x.uid == y.uid
    end
    return x == y
  end

  for trait, v in pairs(ai.active or {}) do
    if not valuesEqual(v, bi.active and bi.active[trait]) then return false end
  end
  for trait, v in pairs(ai.inactive or {}) do
    if not valuesEqual(v, bi.inactive and bi.inactive[trait]) then return false end
  end
  -- Also catch b having traits a lacks -- otherwise a strict subset match
  -- would slip through as "equal".
  for trait in pairs(bi.active or {}) do
    if ai.active == nil or ai.active[trait] == nil then return false end
  end
  return true
end

-- Picks the best destination slot for `incomingStack` among `slots`
-- (an array of slot numbers, not necessarily contiguous -- e.g.
-- config.workingSlots): an existing slot already holding a matching,
-- not-yet-full stack if one exists (so the real inventory slot mechanic
-- merges them instead of us wastefully spreading duplicates across
-- separate slots), otherwise the first empty slot. getStackFn(slot)
-- peeks that slot's raw stack (or nil if empty). Returns nil if neither
-- a mergeable nor an empty slot exists.
local function findStackingSlot(getStackFn, slots, incomingStack)
  local firstEmpty = nil
  for _, slot in ipairs(slots) do
    local existing = getStackFn(slot)
    if existing == nil then
      firstEmpty = firstEmpty or slot
    elseif stacksMatch(existing, incomingStack) and (existing.size or 1) < (existing.maxSize or 64) then
      return slot
    end
  end
  return firstEmpty
end

-- Forestry apiaries expose product/offspring output (combs, drones, the
-- replacement princess) in every slot beyond the queen(1)/drone(2) pair.
-- Confirmed via probeInventoryBelow() against real hardware: the old
-- 7-15 range (inherited from beeManager.lua's Transposer-based version)
-- was flat-out wrong for this apiary -- product was actually sitting in
-- slots 3-6, with 7+ empty. Rather than hardcode another guessed range
-- that might not hold for a different apiary tier/type, this derives
-- "every slot from 3 to the apiary's real reported size" unless
-- config.productSlots explicitly overrides it.
function M.harvestSite(config, site, productSlots)
  productSlots = productSlots or config.productSlots
  Status.setStep("Harvesting " .. (site.name or "?"))
  local ok = gotoSite(site)
  if not ok then return 0 end

  local down = sides().down
  -- A Robot's inventory_controller.suckFromSlot validates the slot against
  -- the TARGET inventory's real size and throws "invalid slot" for
  -- anything beyond it -- unlike a Transposer, which just silently
  -- returns nil for an out-of-range slot. Different apiary tiers/types
  -- have different inventory sizes, so this asks the real hardware
  -- instead of assuming.
  local size = invCtrl().getInventorySize(down)

  if not productSlots then
    productSlots = {}
    for slot = 3, (size or 15) do table.insert(productSlots, slot) end
  end

  local harvested = 0
  for _, productSlot in ipairs(productSlots) do
    if not size or productSlot <= size then
      -- Peeking first isn't just diagnostic -- it avoids burning a
      -- suckFromSlot call (and a working-slot pick) on a slot we can
      -- already see is empty.
      local peek = invCtrl().getStackInSlot(down, productSlot)
      if peek then
        -- Prefers merging into an existing matching, not-yet-full cargo
        -- stack over always taking a fresh empty slot -- without this,
        -- identical harvested drones/combs spread across separate slots
        -- one at a time instead of stacking together.
        local workingSlot = findStackingSlot(invCtrl().getStackInInternalSlot, config.workingSlots, peek)
        if workingSlot then
          -- suckFromSlot lands in the CURRENTLY SELECTED slot, same as
          -- swapQueen/swapDrone/dropIntoSlot elsewhere in this file --
          -- it does not auto-pick an empty slot on its own.
          agent().select(workingSlot)
          local moved = invCtrl().suckFromSlot(down, productSlot, 1)
          if moved and moved > 0 then harvested = harvested + 1 end
        end
      end
    end
  end

  -- One-time-per-site full slot dump if harvesting ever comes up empty
  -- despite the apiary genuinely having a real size -- catches a future
  -- "productSlots doesn't match this apiary" regression the same way
  -- probeInventoryBelow() caught it manually before this existed, without
  -- needing a manual probe step or flooding the log on every normal
  -- "nothing ready yet" cycle.
  if harvested == 0 and size and not diagDumpedSites[site.name] then
    diagDumpedSites[site.name] = true
    local dump = { string.format("[harvest-diag-full] %s: dumping all %d slots:", site.name or "?", size) }
    for slot = 1, size do
      local stack = invCtrl().getStackInSlot(down, slot)
      if stack then
        table.insert(dump, string.format("  slot %d: %s x%s (%s)",
          slot, tostring(stack.name), tostring(stack.size), tostring(stack.label)))
      end
    end
    if #dump == 1 then table.insert(dump, "  (every slot reported empty)") end
    print(table.concat(dump, "\n"))
  end
  return harvested
end

-- ============================================================
-- Storage/trash: fly discarded drones to a position and drop them into the
-- first empty slot found there. Shared by M.dumpToStorage (a plain chest,
-- kept for later) and M.dumpToTrash (e.g. Extra Utilities' Trash Can,
-- permanently voided) -- same mechanic, different destination. Default
-- discard destination when config.onDiscard isn't set (see
-- M.runQualitySite's discard block for the trash-preferred-over-storage
-- ordering).
-- ============================================================

local function dumpEntriesAt(pos, slotCount, discardEntries, keepId)
  if not pos then return 0 end
  local ok = Nav.gotoXZ(pos.x, pos.z)
  if not ok then return 0 end

  slotCount = slotCount or 54
  local candidateSlots = {}
  for s = 1, slotCount do table.insert(candidateSlots, s) end

  local down = sides().down
  local dropped = 0
  for _, entry in ipairs(discardEntries) do
    if entry.drone.id ~= keepId and entry.drone._slot then
      local incoming = invCtrl().getStackInInternalSlot(entry.drone._slot)
      -- Prefers merging into an existing matching, not-yet-full stack
      -- already sitting in storage/trash over always taking a fresh
      -- empty slot -- without this, identical discarded drones pile up
      -- across separate slots one at a time instead of stacking.
      local slot = findStackingSlot(function(s) return invCtrl().getStackInSlot(down, s) end, candidateSlots, incoming)
      if slot then
        agent().select(entry.drone._slot)
        if invCtrl().dropIntoSlot(down, slot) then
          dropped = dropped + 1
        end
      end
    end
  end
  return dropped
end

function M.dumpToStorage(config, discardEntries, keepId)
  Status.setStep("Flying discards to storage")
  return dumpEntriesAt(config.storagePos, config.storageSlotCount, discardEntries, keepId)
end

function M.dumpToTrash(config, discardEntries, keepId)
  Status.setStep("Flying discards to trash")
  return dumpEntriesAt(config.trashPos, config.trashSlotCount or 1, discardEntries, keepId)
end

-- ============================================================
-- Analysis: find unanalyzed bees in working slots and analyze them
-- ============================================================

function M.analyzeWorkingSlots(config)
  local analyzed = 0
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack and stack.individual and not stack.individual.isAnalyzed then
      Status.setStep("Analyzing bee in slot " .. slot)
      agent().select(slot)
      local ok = beekeeper().analyze(config.honeySlot)
      if ok then analyzed = analyzed + 1 end
    end
  end
  return analyzed
end

-- ============================================================
-- Site loading: merges bee_keeper_setup.lua's persisted (x,z) discoveries
-- with the mode/targetSpecies assignments you configure by hand, keyed by
-- site name (site1, site2, ... as assigned during the scan). Anything not
-- explicitly overridden defaults to "traitmax".
-- ============================================================

function M.loadSites(savedSites, siteOverrides)
  siteOverrides = siteOverrides or {}
  local sites = {}
  for _, s in ipairs(savedSites) do
    local override = siteOverrides[s.name] or {}
    table.insert(sites, {
      name = s.name,
      x = s.x,
      z = s.z,
      mode = override.mode or "traitmax",
      targetSpecies = override.targetSpecies,
    })
  end
  return sites
end

-- ============================================================
-- Main cycle
-- ============================================================

-- Runs one full pass over every configured site: harvest, analyze, then
-- dispatch to the right mode's decision function. Sites are visited in
-- nearest-neighbor order from wherever the drone currently is (your
-- call -- direct flight, minimize travel, not fixed list order).
function M.runCycle(config)
  local log = {}
  -- ONE pass per site -- harvest, analyze, then decide/act, all before
  -- moving on to the next apiary. Previously this was TWO full sweeps
  -- (harvest every site, THEN decide/act at every site), which meant an
  -- apiary that still needed a princess seeded or a drone loaded got
  -- left behind while every OTHER site was harvested first, only to be
  -- revisited later in the second sweep -- wasted travel, and looked
  -- like the robot "abandoning" a site that clearly still needed work.
  local orderedSites = Nav.orderByProximity(config.sites)

  for _, site in ipairs(orderedSites) do
    M.harvestSite(config, site)
    -- Cheap and position-independent (operates on the drone's own cargo)
    -- -- calling it once per site instead of once per cycle doesn't cost
    -- any extra travel, and means a bee just harvested at this site is
    -- immediately usable in this SAME site's decision below rather than
    -- waiting for the next site's pass.
    M.analyzeWorkingSlots(config)

    local status
    if site.mode == "traitmax" then
      status = M.runQualitySite(config, site)
    elseif site.mode == "species" then
      status = M.runQualitySite(config, site)
    elseif site.mode == "mutation" then
      status = M.runMutationSite(config, site)
    else
      status = "unknown_mode:" .. tostring(site.mode)
    end
    table.insert(log, string.format("[%s] %s: %s", site.mode, site.name or "?", status))
  end

  if config.needCharge == nil or config.needCharge then
    if Nav.needCharge(config.chargeThreshold) then
      Nav.chargeAtHome(config.chargerPos)
    end
  end

  return log
end

return M
