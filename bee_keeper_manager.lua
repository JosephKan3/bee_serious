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

  NOT IMPLEMENTED YET (per "movement mechanism, later"): Nav.gotoSite below
  is a stub that assumes the agent is ALREADY adjacent to the site. Fill it
  in once travel is built -- nothing else here needs to change, since every
  interaction is side-relative from wherever the agent currently is.

  THREE MODES (per site, set in config.sites[n].mode):
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

local M = {}

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
-- Movement (STUB -- see header notes)
-- ============================================================

local Nav = {}
M.Nav = Nav

-- Get the agent adjacent to `site` and facing the apiary correctly.
-- TODO: not implemented -- assumes the agent is already in position.
-- Replace this with real travel logic; nothing else in this file depends
-- on how that's done, since every hardware call below is already
-- side-relative from wherever the agent currently is.
function Nav.gotoSite(site)
  return true
end

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
  if not Nav.gotoSite(site) then return "nav_failed" end

  local traitList = M.traitListFor(site.mode)
  local targetSpecies = site.targetSpecies

  if beekeeper().canWork(site.side) then
    return string.format("working (%.0f%%)", beekeeper().getBeeProgress(site.side))
  end

  local princessIndividual = M.readSideSlot(site.side, 1)
  if not princessIndividual then
    return "no_princess_at_site"
  end

  local princessBee = toBreedingBee("princess", princessIndividual, traitList, targetSpecies)
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

  -- Discard drones the plan doesn't want, to make room -- physically means
  -- ejecting them (left as a TODO hook: config.onDiscard(bee) if you want
  -- to route them to a sampler/furnace/junk chest instead of just leaving
  -- them in place).
  if config.onDiscard then
    for _, entry in ipairs(plan.toDiscard) do
      if entry.drone.id ~= plan.breedWith.id then
        config.onDiscard(entry.drone)
      end
    end
  end

  agent().select(plan.breedWith._slot)
  local ok = beekeeper().swapDrone(site.side)
  if not ok then return "swap_drone_failed" end

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
  if not Nav.gotoSite(site) then return "nav_failed" end

  if beekeeper().canWork(site.side) then
    return string.format("attempting (%.0f%%)", beekeeper().getBeeProgress(site.side))
  end

  -- Once a mutation succeeds, some harvested offspring will be
  -- targetSpecies -- check the working slots for one before planning
  -- another attempt, so a lucky success isn't immediately overwritten.
  local traitList = M.traitListFor("mutation")
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

  agent().select(plan.princessSlot)
  if not beekeeper().swapQueen(site.side) then return "swap_queen_failed" end
  agent().select(plan.droneSlot)
  if not beekeeper().swapDrone(site.side) then return "swap_drone_failed" end

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
  if not Nav.gotoSite(site) then return 0 end

  local harvested = 0
  for _, productSlot in ipairs(productSlots) do
    for _, workingSlot in ipairs(config.workingSlots) do
      if M.readOwnSlot(workingSlot) == nil then
        local moved = invCtrl().suckFromSlot(site.side, productSlot, 1, nil)
        if moved and moved > 0 then harvested = harvested + 1 end
        break
      end
    end
  end
  return harvested
end

-- ============================================================
-- Analysis: find unanalyzed bees in working slots and analyze them
-- ============================================================

function M.analyzeWorkingSlots(config)
  local analyzed = 0
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack and stack.individual and not stack.individual.isAnalyzed then
      agent().select(slot)
      local ok = beekeeper().analyze(config.honeySlot)
      if ok then analyzed = analyzed + 1 end
    end
  end
  return analyzed
end

-- ============================================================
-- Main cycle
-- ============================================================

-- Runs one full pass over every configured site: harvest, analyze, then
-- dispatch to the right mode's decision function.
function M.runCycle(config)
  local log = {}

  for _, site in ipairs(config.sites) do
    M.harvestSite(config, site)
  end

  M.analyzeWorkingSlots(config)

  for _, site in ipairs(config.sites) do
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

  return log
end

return M
