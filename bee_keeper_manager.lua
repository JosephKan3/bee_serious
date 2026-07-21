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

-- The "robot" LIBRARY (require("robot")), not component.robot -- needed
-- for inventorySize(), which reports the agent's OWN total slot count.
-- inventory_controller.getInventorySize(side) is for EXTERNAL
-- inventories and REQUIRES a side argument -- confirmed on real hardware
-- ("bad arguments #1 (integer expected, got no value)") when called with
-- none, which is what querying "my own size" would need. Same
-- library-vs-component split bee_keeper_nav.lua already established for
-- movement.
local function robotLib() return require("robot") end

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

local function isDroneStack(stack)
  if not stack or not stack.name then return false end
  return stack.name:lower():find("drone") ~= nil
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

-- Finds the HIGHEST-QUALITY analyzed princess/queen sitting in the
-- agent's own cargo, for seeding an apiary whose queen slot has gone
-- empty (see the no-princess branch in M.runQualitySite below for why
-- this is needed at all). Scored the same way as the mutation flow's
-- bestOfSpecies -- picking merely the FIRST candidate found (old
-- behavior) meant whichever princess happened to sit in the lowest-
-- numbered cargo slot got stuck in whichever apiary was visited first
-- (nearest-neighbor travel order), regardless of quality -- a genuinely
-- better princess could just as easily end up seeded at a LATER site
-- purely by luck of scan order, leaving a good drone (matched against
-- her via BB.planGeneration below) paired with a weak princess at the
-- site visited first, while a stronger princess sat unseeded in cargo.
-- Scoring here means the best available princess is always seeded
-- first, and with multiple apiaries needing seeding in the same cycle,
-- each one (visited in travel order) gets the best REMAINING princess
-- -- good pairs with good by construction, not accident.
-- Returns the working slot number, or nil if cargo has no usable
-- princess/queen at all.
local function findPrincessCandidate(config, traitList, targetSpecies)
  local bestSlot, bestScore = nil, -1
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if isPrincessOrQueenStack(stack) then
      local individual = readIndividual(stack)
      if individual then
        local genotype = Cfg.normalizeGenotype(traitList, individual.active, individual.inactive, targetSpecies)
        local score = M.purityOf(traitList, genotype)
        if score > bestScore then
          bestScore = score
          bestSlot = slot
        end
      end
    end
  end
  return bestSlot
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
    local progress = beekeeper().getBeeProgress(down)
    -- getBeeProgress is what actually COMPLETES breeding on its final
    -- tick (consumes the queen, creates her offspring/output) -- if
    -- she's still there afterward, this visit's work genuinely isn't
    -- done yet, so report progress and leave. But if she's now GONE,
    -- breeding just finished on THIS call, and the apiary would
    -- otherwise sit idle for a whole extra cycle (robot leaves, has to
    -- come all the way back) before the seed+evaluate+load logic below
    -- ever runs again -- so fall through into it in this SAME visit
    -- instead, same principle as the earlier fix that stopped a
    -- princess being seeded without a drone loaded in the same visit.
    if M.readSideSlot(down, 1) ~= nil then
      return string.format("working (%.0f%%)", progress)
    end

    -- Breeding just completed -- her offspring/output is sitting in the
    -- apiary's product slots RIGHT NOW, not yet in cargo, and definitely
    -- not analyzed yet. Harvest and analyze it immediately, before
    -- falling through to seed+evaluate+load below, so it's actually
    -- available as a candidate for the very next pairing decision
    -- instead of sitting unanalyzed until some later, unrelated visit.
    M.harvestSite(config, site)
    M.analyzeWorkingSlots(config)
  end

  local princessIndividual = M.readSideSlot(down, 1)
  local seededThisVisit = false
  if not princessIndividual then
    -- The apiary's queen slot is empty. This isn't necessarily "never
    -- had one" -- a spent queen is fully CONSUMED by Forestry once she
    -- finishes breeding, and her replacement offspring princess lands in
    -- the product/output area (confirmed via probeInventoryBelow()), NOT
    -- back in the queen slot. Nothing else in this file ever re-seeds a
    -- princess for traitmax/species sites (only the mutation flow calls
    -- swapQueen), so without this, a site goes permanently idle the
    -- moment its queen runs out.
    local princessSlot = findPrincessCandidate(config, traitList, targetSpecies)
    if not princessSlot then
      return "no_princess_at_site_or_in_cargo"
    end
    Status.setStep("Seeding princess into " .. (site.name or "?"))
    agent().select(princessSlot)
    if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
    -- Continue straight into drone evaluation/loading below, in this
    -- SAME visit, instead of leaving the apiary half set up (a princess
    -- but no drone) until whenever it happens to be revisited again --
    -- she's immediately readable back out via readSideSlot now that
    -- she's actually installed, nothing technical requires waiting for
    -- a separate cycle. This is what real-hardware watching caught:
    -- the robot visibly "abandoning" an apiary mid-setup to wander off
    -- elsewhere, only coming back to finish it much later (if a
    -- different site's turn didn't get there first).
    princessIndividual = M.readSideSlot(down, 1)
    if not princessIndividual then return "swap_queen_failed_readback" end
    seededThisVisit = true
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
    return seededThisVisit and "seeded princess (no drone candidates in cargo yet)"
      or "no_candidate_drones_in_working_slots"
  end

  local endgame = BB.isPhenotypicallyPerfect(traitList, princessBee.genotype)
  local plan = BB.planGeneration(traitList, princessBee.genotype, dronePool, {}, endgame,
    config.minCopies, Cfg.weights)

  if not plan.breedWith then
    return seededThisVisit and "seeded princess (no viable drone yet)" or "no_viable_drone"
  end

  -- Load the winning drone FIRST, while still standing right at the site
  -- -- no reason to make discarding the losers a detour in between
  -- deciding and actually finishing the setup. Discarding is handled
  -- afterward instead (see below): it doesn't need the winner loaded
  -- first, and putting it after means this apiary is fully set up
  -- (princess + drone both in) before the robot goes anywhere else, same
  -- principle as the earlier fix that stopped it seeding a princess and
  -- wandering off before loading a drone at all.
  Status.setStep("Loading drone into " .. (site.name or "?"))
  local droneSlot = ensureSingleItemSlot(config, plan.breedWith._slot)
  if not droneSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(droneSlot)
  local swapped = beekeeper().swapDrone(down)
  if not swapped then return "swap_drone_failed" end

  -- Discard drones the plan doesn't want, to make room. Default behavior:
  -- fly them to config.trashPos (permanently voided -- see M.dumpToTrash)
  -- if known, else config.storagePos (see M.dumpToStorage) -- trash is
  -- preferred when both are known, since a breeding program generates a
  -- steady stream of unwanted drones that would otherwise slowly fill up
  -- a finite storage chest. Override config.onDiscard to route elsewhere
  -- entirely (sampler/furnace/junk). No trip back to the site afterward
  -- needed -- the apiary is already fully loaded, and wherever this
  -- discard trip ends is a perfectly fine place to start the next site's
  -- travel from.
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
  end

  return string.format("%sloaded drone (score %.1f)", seededThisVisit and "seeded princess + " or "", plan.score)
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
-- keeping SEPARATE princess-capable and drone-capable lists per species.
-- Forestry doesn't care which NAMED species ends up as the princess vs
-- the drone in a mutation -- but it absolutely cares that the princess
-- slot gets an actual princess/queen item and the drone slot gets an
-- actual drone. Mixing both roles into one list per species (the old
-- behavior) could pick a DRONE as the "princess" candidate whenever it
-- happened to score best, which swapQueen then correctly rejects.
local function groupBySpecies(config)
  local bySpecies = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local individual = readIndividual(stack)
    if individual then
      local name = Cfg.speciesKey(individual.active.species)
      bySpecies[name] = bySpecies[name] or { princesses = {}, drones = {} }
      local entry = { slot = slot, individual = individual }
      if isPrincessOrQueenStack(stack) then
        table.insert(bySpecies[name].princesses, entry)
      elseif isDroneStack(stack) then
        table.insert(bySpecies[name].drones, entry)
      end
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
    local groupA = held[nameA]
    local groupB = held[nameB]

    -- Try both arrangements -- Forestry doesn't care which NAMED species
    -- ends up as the princess vs the drone, only that one side is a
    -- genuine princess/queen and the other a genuine drone.
    local arrangement = nil
    if groupA and groupB and #groupA.princesses > 0 and #groupB.drones > 0 then
      arrangement = { princessGroup = groupA.princesses, droneGroup = groupB.drones,
                       princessSpecies = nameA, droneSpecies = nameB }
    elseif groupA and groupB and #groupB.princesses > 0 and #groupA.drones > 0 then
      arrangement = { princessGroup = groupB.princesses, droneGroup = groupA.drones,
                       princessSpecies = nameB, droneSpecies = nameA }
    end

    if arrangement then
      if recipe.chance > bestChance then
        local princessPick = bestOfSpecies(arrangement.princessGroup, traitList)
        local dronePick = bestOfSpecies(arrangement.droneGroup, traitList)
        bestChance = recipe.chance
        best = { princessSlot = princessPick.slot, droneSlot = dronePick.slot, chance = recipe.chance,
                 princessSpecies = arrangement.princessSpecies, droneSpecies = arrangement.droneSpecies }
      end
    elseif not missingReport then
      missingReport = string.format("need a princess/queen of '%s' and a drone of '%s' (or vice versa) (%.0f%% base chance)",
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
    local progress = beekeeper().getBeeProgress(down)
    -- Same reasoning as runQualitySite's identical check: getBeeProgress
    -- completes the attempt on its final tick (consumes the queen) --
    -- if she's gone now, fall through into planning/loading the next
    -- attempt in this SAME visit instead of leaving the site idle for a
    -- whole extra cycle.
    if M.readSideSlot(down, 1) ~= nil then
      return string.format("attempting (%.0f%%)", progress)
    end

    -- Same reasoning as runQualitySite's identical step: harvest and
    -- analyze the just-created offspring/output immediately, before
    -- planning the next attempt below, so it's actually available as a
    -- candidate right away.
    M.harvestSite(config, site)
    M.analyzeWorkingSlots(config)
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
          -- it does not auto-pick an empty slot on its own. Pulls the
          -- WHOLE stack in one go (peek.size), not a hardcoded 1 -- a
          -- product slot holding several genetically identical drones
          -- (they stack, same as cargo) otherwise only ever gave up one
          -- unit per visit, leaving the rest sitting there indefinitely
          -- since a fresh visit re-peeks and re-splits the same way
          -- every time. Real hardware/suckFromSlot itself still caps
          -- this at whatever the destination has room for, same as any
          -- other transfer.
          agent().select(workingSlot)
          local moved = invCtrl().suckFromSlot(down, productSlot, peek.size)
          if moved and moved > 0 then harvested = harvested + moved end
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
-- Restocking: pull analyzed bees back OUT of storage into free working
-- slots. Without this, once a drone is flown to storage it's gone from
-- the breeding pool forever from the algorithm's point of view, even
-- though it's still physically sitting right there -- storage becomes a
-- one-way trip instead of a real fallback pool. Called from M.runCycle
-- when a site's decision came up empty-handed (no usable candidates in
-- cargo at all).
-- ============================================================

function M.restockFromStorage(config)
  if not config.storagePos then return 0 end

  local freeSlots = {}
  for _, slot in ipairs(config.workingSlots) do
    if invCtrl().getStackInInternalSlot(slot) == nil then table.insert(freeSlots, slot) end
  end
  if #freeSlots == 0 then return 0 end

  Status.setStep("Restocking from storage")
  local ok = Nav.gotoXZ(config.storagePos.x, config.storagePos.z)
  if not ok then return 0 end

  local down = sides().down
  local size = invCtrl().getInventorySize(down) or config.storageSlotCount or 54
  local restocked = 0
  local freeIdx = 1
  for slot = 1, size do
    if freeIdx > #freeSlots then break end
    local stack = invCtrl().getStackInSlot(down, slot)
    if stack and readIndividual(stack) then
      agent().select(freeSlots[freeIdx])
      local moved = invCtrl().suckFromSlot(down, slot, 1)
      if moved and moved > 0 then
        restocked = restocked + 1
        freeIdx = freeIdx + 1
      end
    end
  end
  return restocked
end

-- ============================================================
-- Analysis: find unanalyzed bees in working slots and analyze them
-- ============================================================

-- Finds honey/honeydew wherever it actually is in the agent's own
-- inventory, rather than assuming it's permanently sitting in
-- config.honeySlot. Searches the WHOLE inventory (not just
-- workingSlots, which deliberately excludes honeySlot by convention).
-- Returns nil if nothing matches -- NO config.honeySlot fallback here
-- (see M.analyzeWorkingSlots, which tries restocking from storage first
-- and only falls back to the configured slot as an absolute last
-- resort).
local function searchForHoney()
  local size = robotLib().inventorySize() or 16
  for slot = 1, size do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack and stack.name then
      local lower = stack.name:lower()
      if lower:find("honey") or lower:find("honeydew") then
        return slot
      end
    end
  end
  return nil
end

-- Sums EVERY honey/honeydew stack currently in cargo (not just the
-- first one found -- see searchForHoney), across the robot's FULL
-- inventory. Used to seed/true-up config.honeyCount, the running
-- estimate M.runCycle checks proactively each cycle (see its header
-- notes) instead of only reacting after a site's own analysis attempt
-- already discovers cargo is empty.
local function countHoneyInCargo()
  local size = robotLib().inventorySize() or 16
  local total = 0
  for slot = 1, size do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack and stack.name then
      local lower = stack.name:lower()
      if lower:find("honey") or lower:find("honeydew") then
        total = total + (stack.size or 1)
      end
    end
  end
  return total
end
M.countHoneyInCargo = countHoneyInCargo

-- Tracks whether the "nothing matched honey/honeydew by name" full dump
-- (see M.restockHoney below) has already fired once, so a persistently
-- empty/mismatched storage doesn't flood the log every cycle.
local diagRestockDumped = false

-- Flies to a honey source (config.honeyStoragePos, a dedicated location
-- if you keep honey separate from general storage, falling back to
-- config.storagePos) and pulls a full stack back into a free working
-- slot. Without this, once cargo's honey genuinely runs dry there was no
-- way to recover even with a full stack sitting in a chest -- analysis
-- would just silently stop working forever.
function M.restockHoney(config)
  local honeyPos = config.honeyStoragePos or config.storagePos
  if not honeyPos then return false end

  -- Prefer refilling config.honeySlot itself if it's empty. Once its
  -- honey is fully consumed the slot becomes empty too, but it's
  -- deliberately excluded from config.workingSlots (M.resolveWorkingSlots
  -- keeps it out of the breeding-candidate pool on purpose), so a search
  -- limited to workingSlots would never even consider it. Real hardware
  -- hit exactly this: once cargo filled up with banked drones/princesses
  -- (leaving no free WORKING slot at all), restocking honey failed
  -- outright even though the most natural destination -- honeySlot
  -- itself -- was sitting right there, empty, ready to be refilled.
  local freeSlot = nil
  if config.honeySlot and invCtrl().getStackInInternalSlot(config.honeySlot) == nil then
    freeSlot = config.honeySlot
  else
    for _, slot in ipairs(config.workingSlots) do
      if invCtrl().getStackInInternalSlot(slot) == nil then
        freeSlot = slot
        break
      end
    end
  end
  if not freeSlot then return false end

  Status.setStep("Fetching honey from storage")
  local ok = Nav.gotoXZ(honeyPos.x, honeyPos.z)
  if not ok then return false end

  local down = sides().down
  local size = invCtrl().getInventorySize(down) or config.storageSlotCount or 54
  for slot = 1, size do
    local stack = invCtrl().getStackInSlot(down, slot)
    if stack and stack.name then
      local lower = stack.name:lower()
      if lower:find("honey") or lower:find("honeydew") then
        agent().select(freeSlot)
        local moved = invCtrl().suckFromSlot(down, slot, 64)
        if moved and moved > 0 then return true end
        -- Matched by name, but suckFromSlot moved nothing -- fires
        -- immediately, not gated by diagRestockDumped, since this is a
        -- much more specific/unusual failure worth seeing right away
        -- (e.g. the destination slot rejected it, or the source
        -- reported a stack that wasn't actually still there).
        print(string.format(
          "[restock-diag] matched slot %d (%s x%s) by name, but suckFromSlot(side=%s, slot=%d, count=64) into freeSlot=%d moved %s",
          slot, tostring(stack.name), tostring(stack.size), tostring(down), slot, freeSlot, tostring(moved)))
      end
    end
  end

  -- One-time full dump if NOTHING in the whole inventory ever matched
  -- "honey"/"honeydew" by name -- same reasoning as M.harvestSite's own
  -- "harvest-diag-full" dump: catches a real-hardware naming mismatch
  -- (this pack's actual item name/label not containing either substring)
  -- directly in the log, instead of restockHoney just silently
  -- returning false forever with zero forensic information.
  if not diagRestockDumped then
    diagRestockDumped = true
    local dump = { string.format("[restock-diag-full] %s: dumping all %d slots, nothing matched honey/honeydew by name:",
      tostring(honeyPos and (honeyPos.x .. "," .. honeyPos.z)), size) }
    for slot = 1, size do
      local stack = invCtrl().getStackInSlot(down, slot)
      if stack then
        table.insert(dump, string.format("  slot %d: name=%s label=%s x%s",
          slot, tostring(stack.name), tostring(stack.label), tostring(stack.size)))
      end
    end
    if #dump == 1 then table.insert(dump, "  (every slot reported empty)") end
    print(table.concat(dump, "\n"))
  end

  return false
end

function M.analyzeWorkingSlots(config)
  local analyzed = 0
  local honeySlot = searchForHoney()
  if not honeySlot then
    -- Cargo genuinely has none -- try fetching more before giving up.
    if M.restockHoney(config) then
      config.honeyCount = countHoneyInCargo()
      honeySlot = searchForHoney()
    end
  end
  -- Absolute last resort: real hardware might report a different item
  -- name than expected -- better to try the configured slot than
  -- analyze nothing at all.
  honeySlot = honeySlot or config.honeySlot
  if not honeySlot then return 0 end

  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack and stack.individual and not stack.individual.isAnalyzed then
      -- Honey ran out partway through THIS SAME batch (several
      -- unanalyzed bees in one visit, more than one stack's worth of
      -- honey) -- restock immediately, high priority, rather than
      -- leaving the rest of this visit's bees unanalyzed until some
      -- unrelated later cycle happens to trigger a restock.
      if config.honeyCount and config.honeyCount <= 0 then
        if M.restockHoney(config) then
          config.honeyCount = countHoneyInCargo()
          honeySlot = searchForHoney() or honeySlot
        end
      end
      Status.setStep("Analyzing bee in slot " .. slot)
      agent().select(slot)
      local ok = beekeeper().analyze(honeySlot)
      if ok then
        analyzed = analyzed + 1
        if config.honeyCount then config.honeyCount = math.max(0, config.honeyCount - 1) end
      end
    end
  end
  return analyzed
end

-- ============================================================
-- Working slots: if config.workingSlots isn't explicitly set, use every
-- slot from 1 to the robot's REAL inventory size except honeySlot,
-- instead of a fixed hardcoded list. A fixed list (e.g. hardcoded to 16)
-- silently wastes any additional Inventory Upgrade slots the robot
-- actually has installed -- call this once at startup (see
-- bee_keeper_manager_run.lua) and assign the result back into
-- config.workingSlots.
-- ============================================================

function M.resolveWorkingSlots(config)
  if config.workingSlots then return config.workingSlots end
  local size = robotLib().inventorySize() or 16
  local slots = {}
  for slot = 1, size do
    if slot ~= config.honeySlot then table.insert(slots, slot) end
  end
  return slots
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

  -- Proactive, HIGH-PRIORITY honey restock -- config.honeyCount is a
  -- running estimate (persists on the config table across cycles),
  -- seeded by a real scan the first time it's unknown, then kept in
  -- sync incrementally: decremented once per successful analyze() (see
  -- M.analyzeWorkingSlots), and true-up'd via a fresh countHoneyInCargo()
  -- scan after any successful restock trip. Checked here BEFORE any
  -- site is even visited, so a low stock gets topped up first thing,
  -- rather than only reacting after a site's own analysis attempt
  -- already discovers cargo is empty (which, on real hardware, could
  -- mean re-scanning the wrong thing or missing a restock opportunity
  -- entirely -- reported: honey restocked successfully once, then
  -- stopped restocking on subsequent runs). config.honeyRestockThreshold
  -- (default 5) is a buffer, not zero -- a single visit can need
  -- several honey units at once (multiple unanalyzed bees), so topping
  -- up a little early avoids running out mid-visit.
  if config.honeyCount == nil then
    config.honeyCount = countHoneyInCargo()
  end
  if config.honeyCount <= (config.honeyRestockThreshold or 5) then
    if M.restockHoney(config) then
      config.honeyCount = countHoneyInCargo()
    end
  end

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

    -- Catch anything the decide-phase itself just produced (a queen's
    -- FINAL work tick creates her offspring/output immediately, inside
    -- runQualitySite/runMutationSite's own getBeeProgress call, which
    -- runs AFTER harvestSite above in this same visit). Without this,
    -- freshly bred output sits unharvested for a full extra cycle even
    -- though the robot is still standing right there -- it only gets
    -- picked up the NEXT time this apiary happens to be visited again.
    -- No extra travel: gotoSite/harvestSite is a no-op if there's
    -- nothing new to harvest.
    M.harvestSite(config, site)
  end

  -- If any site came up genuinely empty-handed this cycle, storage might
  -- still have something usable sitting in it -- one bounded trip (not
  -- per-site) pulls bees back into cargo so the NEXT cycle's decisions
  -- actually see them, instead of storage being a one-way trip nothing
  -- ever gets read back from.
  local needsRestock = false
  for _, entry in ipairs(log) do
    if entry:find("no_candidate_drones_in_working_slots", 1, true)
      or entry:find("no_princess_at_site_or_in_cargo", 1, true) then
      needsRestock = true
    end
  end
  if needsRestock then
    local restocked = M.restockFromStorage(config)
    if restocked > 0 then
      table.insert(log, string.format("[restock] pulled %d bee(s) back from storage", restocked))
    end
  end

  if config.needCharge == nil or config.needCharge then
    if Nav.needCharge(config.chargeThreshold) then
      Nav.chargeAtHome(config.chargerPos)
    end
  end

  return log
end

return M
