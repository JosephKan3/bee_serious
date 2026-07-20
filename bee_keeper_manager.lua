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

-- Gathers usable candidate drones from the working slots (analyzed bees
-- only -- unanalyzed ones are queued for analysis instead, see
-- M.analyzeWorkingSlots).
local function gatherCandidateDrones(config, traitList, targetSpecies)
  local pool = {}
  for _, slot in ipairs(config.workingSlots) do
    local individual = M.readOwnSlot(slot)
    if individual then
      local bee = toBreedingBee("slot" .. slot, individual, traitList, targetSpecies)
      bee._slot = slot
      table.insert(pool, bee)
    end
  end
  return pool
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
    return "no_princess_at_site"
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
  -- fly them to config.storagePos and drop them there (see M.dumpToStorage)
  -- -- override config.onDiscard to route elsewhere (sampler/furnace/junk).
  local discardCount = 0
  for _, entry in ipairs(plan.toDiscard) do
    if entry.drone.id ~= plan.breedWith.id then
      discardCount = discardCount + 1
      if config.onDiscard then
        config.onDiscard(entry.drone)
      end
    end
  end
  if discardCount > 0 and not config.onDiscard and config.storagePos then
    M.dumpToStorage(config, plan.toDiscard, plan.breedWith.id)
    -- dumpToStorage flew away to drop off discards -- come back before
    -- finishing the swap below, or it lands on the storage chest instead
    -- of the apiary (caught by the local simulator: swapDrone would fail
    -- there since there's no apiary at the storage position).
    local backOk, backReason = gotoSite(site)
    if not backOk then return "nav_failed_returning_from_storage:" .. tostring(backReason) end
  end

  Status.setStep("Loading drone into " .. (site.name or "?"))
  agent().select(plan.breedWith._slot)
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
  agent().select(plan.droneSlot)
  if not beekeeper().swapDrone(down) then return "swap_drone_failed" end

  return string.format("attempting mutation %s x %s (%.0f%% base chance)",
    plan.princessSpecies, plan.droneSpecies, plan.chance)
end

-- ============================================================
-- Harvesting: pull an apiary's product slots into working slots
-- ============================================================

-- Forestry apiaries expose product/offspring output in slots beyond the
-- queen(1)/drone(2) pair (see beeManager.lua's old scanApiaries, which
-- cleared slots 7-15 via transposer -- same idea, now via
-- inventory_controller.suckFromSlot instead of a transposer).
function M.harvestSite(config, site, productSlots)
  productSlots = productSlots or config.productSlots or { 7, 8, 9, 10, 11, 12, 13, 14, 15 }
  Status.setStep("Harvesting " .. (site.name or "?"))
  local ok = gotoSite(site)
  if not ok then return 0 end

  local down = sides().down
  -- A Robot's inventory_controller.suckFromSlot validates the slot against
  -- the TARGET inventory's real size and throws "invalid slot" for
  -- anything beyond it -- unlike a Transposer (what the old beeManager.lua
  -- used with this same 7-15 range), which just silently returns nil for
  -- an out-of-range slot. Different apiary tiers/types have different
  -- inventory sizes, so this asks the real hardware instead of assuming.
  local size = invCtrl().getInventorySize(down)
  local harvested = 0
  for _, productSlot in ipairs(productSlots) do
    if not size or productSlot <= size then
      for _, workingSlot in ipairs(config.workingSlots) do
        if M.readOwnSlot(workingSlot) == nil then
          -- suckFromSlot lands in the CURRENTLY SELECTED slot, same as
          -- swapQueen/swapDrone/dropIntoSlot elsewhere in this file --
          -- it does not auto-pick an empty slot on its own. Without this,
          -- it silently lands in (or fails against) whatever slot was
          -- selected last, which is why harvesting produced nothing on
          -- real hardware despite the apiary genuinely having product to
          -- pull.
          agent().select(workingSlot)
          local moved = invCtrl().suckFromSlot(down, productSlot, 1)
          if moved and moved > 0 then harvested = harvested + 1 end
          break
        end
      end
    end
  end
  return harvested
end

-- ============================================================
-- Storage: fly discarded drones to config.storagePos and drop them in a
-- plain chest (MVP -- see bee_keeper_manager_config.lua). Default discard
-- destination when config.onDiscard isn't set.
-- ============================================================

function M.dumpToStorage(config, discardEntries, keepId)
  if not config.storagePos then return 0 end
  Status.setStep("Flying discards to storage")
  local ok = Nav.gotoXZ(config.storagePos.x, config.storagePos.z)
  if not ok then return 0 end

  local down = sides().down
  local dropped = 0
  for _, entry in ipairs(discardEntries) do
    if entry.drone.id ~= keepId and entry.drone._slot then
      agent().select(entry.drone._slot)
      for storageSlot = 1, (config.storageSlotCount or 54) do
        if invCtrl().getStackInSlot(down, storageSlot) == nil then
          if invCtrl().dropIntoSlot(down, storageSlot) then
            dropped = dropped + 1
          end
          break
        end
      end
    end
  end
  return dropped
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
  local orderedSites = Nav.orderByProximity(config.sites)

  for _, site in ipairs(orderedSites) do
    M.harvestSite(config, site)
  end

  M.analyzeWorkingSlots(config)

  orderedSites = Nav.orderByProximity(config.sites)
  for _, site in ipairs(orderedSites) do
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
