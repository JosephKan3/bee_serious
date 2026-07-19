--[[
  Mock-based tests for bee_keeper_manager.lua.

  There's no OpenComputers/Minecraft runtime to test against here, so this
  fakes "component" and "sides" (the only two hardware-touching requires)
  with an in-memory simulated world: a table of apiary slots per side, and
  a table of the agent's own inventory slots. bee_keeper_manager's actual
  decision logic (which drone to pick, which mutation pair to load, etc.)
  runs for real against these fakes -- only the world I/O is simulated, not
  the logic being tested.
--]]

-- ============================================================
-- Fakes: sides, component
-- ============================================================

package.loaded["sides"] = {
  north = 2, south = 3, east = 4, west = 5, up = 0, down = 1,
}

local world = {
  apiaries = {},  -- [side] = { [slot] = stack }
  agentInventory = {},  -- [slot] = stack
  selectedSlot = 1,
  analyzeCalls = 0,
  honey = 64,
}

local function apiary(side)
  world.apiaries[side] = world.apiaries[side] or {}
  return world.apiaries[side]
end

local function makeAlleles(traitList, goodTraits)
  local active, inactive = {}, {}
  for _, t in ipairs(traitList) do
    if t == "species" then
      active[t] = goodTraits.species or { name = "Common" }
      inactive[t] = goodTraits.species or { name = "Common" }
    else
      active[t] = goodTraits[t] ~= nil and goodTraits[t] or 0
      inactive[t] = goodTraits[t] ~= nil and goodTraits[t] or 0
    end
  end
  return active, inactive
end

-- Builds a mock "stack" (what getStackInSlot/getStackInInternalSlot would
-- return) wrapping an individual, matching beeManager.lua's established
-- .individual.active/.inactive convention.
local function mockBeeStack(active, inactive, isAnalyzed)
  if isAnalyzed == nil then isAnalyzed = true end
  return { name = "forestry:bee", individual = { active = active, inactive = inactive, isAnalyzed = isAnalyzed } }
end

local mockComponent = {}
mockComponent.isAvailable = function(name) return name == "robot" end

mockComponent.robot = {
  select = function(slot) world.selectedSlot = slot end,
}

mockComponent.inventory_controller = {
  getStackInInternalSlot = function(slot)
    return world.agentInventory[slot]
  end,
  getStackInSlot = function(side, slot)
    return apiary(side)[slot]
  end,
  suckFromSlot = function(side, slot, count)
    local stack = apiary(side)[slot]
    if not stack then return 0 end
    for i = 1, 16 do
      if world.agentInventory[i] == nil then
        world.agentInventory[i] = stack
        apiary(side)[slot] = nil
        return 1
      end
    end
    return 0
  end,
}

mockComponent.beekeeper = {
  canWork = function(side) return apiary(side)._working or false end,
  getBeeProgress = function(side) return apiary(side)._progress or 0 end,
  swapQueen = function(side)
    local a = apiary(side)
    local newQueen = world.agentInventory[world.selectedSlot]
    local oldQueen = a[1]
    a[1] = newQueen
    world.agentInventory[world.selectedSlot] = oldQueen
    return true
  end,
  swapDrone = function(side)
    local a = apiary(side)
    local newDrone = world.agentInventory[world.selectedSlot]
    local oldDrone = a[2]
    a[2] = newDrone
    world.agentInventory[world.selectedSlot] = oldDrone
    return true
  end,
  analyze = function(honeySlot)
    world.analyzeCalls = world.analyzeCalls + 1
    local stack = world.agentInventory[world.selectedSlot]
    if stack and stack.individual then stack.individual.isAnalyzed = true end
    return true
  end,
}

mockComponent.bee_housing = {
  getBeeParents = function(species) return world._mutationRecipes and world._mutationRecipes[species] or {} end,
}

package.loaded["component"] = mockComponent

-- ============================================================
-- Load the real module under test against these fakes
-- ============================================================

local M = require("bee_keeper_manager")
local Cfg = require("bee_trait_config")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- ============================================================
-- Test: traitListFor
-- ============================================================

do
  local qualityOnly = M.traitListFor("traitmax")
  local hasSpecies = false
  for _, t in ipairs(qualityOnly) do if t == "species" then hasSpecies = true end end
  check("traitListFor(traitmax) excludes species", not hasSpecies)

  local withSpecies = M.traitListFor("species")
  hasSpecies = false
  for _, t in ipairs(withSpecies) do if t == "species" then hasSpecies = true end end
  check("traitListFor(species) includes species", hasSpecies)
end

-- ============================================================
-- Test: readIndividual handles both shapes + rejects unanalyzed/nil
-- ============================================================

do
  local wrapped = mockBeeStack({ fertility = 4 }, { fertility = 4 }, true)
  check("readIndividual unwraps .individual", M.readIndividual(wrapped) ~= nil)

  local flat = { active = { fertility = 4 }, inactive = { fertility = 4 }, isAnalyzed = true }
  check("readIndividual accepts flat (bee_housing) shape", M.readIndividual(flat) ~= nil)

  local unanalyzed = mockBeeStack({ fertility = 4 }, { fertility = 4 }, false)
  check("readIndividual rejects unanalyzed", M.readIndividual(unanalyzed) == nil)

  check("readIndividual rejects nil", M.readIndividual(nil) == nil)
end

-- ============================================================
-- Test: runQualitySite picks the correct best drone and actually swaps it
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}

  local traitList = M.traitListFor("traitmax")
  -- Princess: good at everything except fertility.
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1 -- below the atLeast-4 target -> "bad"

  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(2)[1] = mockBeeStack(pActive, pInactive, true) -- side "north" = 2

  -- Working slot 5: a weak drone (nothing good).
  local weakActive, weakInactive = makeAlleles(traitList, {})
  world.agentInventory[5] = mockBeeStack(weakActive, weakInactive, true)

  -- Working slot 6: carries good fertility -- should be picked.
  local strongTraits = {}
  strongTraits.fertility = Cfg.targets.fertility.target
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[6] = mockBeeStack(strongActive, strongInactive, true)

  local config = { workingSlots = { 5, 6 }, minCopies = 2 }
  local site = { name = "test-site", side = 2, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite reports a load", status:match("^loaded drone") ~= nil, status)
  check("runQualitySite selected slot 6 (fertility carrier)", world.selectedSlot == 6, "selected=" .. tostring(world.selectedSlot))
  check("runQualitySite actually swapped the drone into the apiary", apiary(2)[2] ~= nil and apiary(2)[2].individual.active.fertility == Cfg.targets.fertility.target)
  check("runQualitySite pulled the weak drone's slot back out (still slot 5 in inventory, untouched)", world.agentInventory[5] ~= nil)
end

-- ============================================================
-- Test: mutation mode matches held species against recipes and swaps in
-- the correct pair
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world._mutationRecipes = {
    ["NewSpecies"] = {
      { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
      { allele1 = { name = "Common" }, allele2 = { name = "Cultivated" }, chance = 8 },
    },
  }

  local traitList = M.traitListFor("mutation")
  local forestActive, forestInactive = makeAlleles(traitList, { species = { name = "Forest" } })
  local meadowsActive, meadowsInactive = makeAlleles(traitList, { species = { name = "Meadows" } })

  -- Only Forest x Meadows is satisfiable (no Common/Cultivated held) --
  -- should be the one picked even though it's not literally the only recipe.
  world.agentInventory[3] = mockBeeStack(forestActive, forestInactive, true)
  world.agentInventory[4] = mockBeeStack(meadowsActive, meadowsInactive, true)

  local config = { workingSlots = { 3, 4 } }
  local site = { name = "mutation-site", side = 4, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports an attempt", status:match("^attempting mutation") ~= nil, status)
  check("runMutationSite loaded a queen", apiary(4)[1] ~= nil)
  check("runMutationSite loaded a drone", apiary(4)[2] ~= nil)

  local queenSpecies = Cfg.speciesKey(apiary(4)[1].individual.active.species)
  local droneSpecies = Cfg.speciesKey(apiary(4)[2].individual.active.species)
  check("runMutationSite used the satisfiable Forest/Meadows pair",
    (queenSpecies == "Forest" and droneSpecies == "Meadows") or (queenSpecies == "Meadows" and droneSpecies == "Forest"),
    "queen=" .. tostring(queenSpecies) .. " drone=" .. tostring(droneSpecies))
end

-- ============================================================
-- Test: mutation mode reports missing parents when nothing's satisfiable
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world._mutationRecipes = {
    ["NewSpecies"] = {
      { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
    },
  }
  local config = { workingSlots = { 3, 4 } }
  local site = { name = "mutation-site", side = 4, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports waiting when parents aren't held", status:match("^waiting_on_parent_species") ~= nil, status)
end

-- ============================================================
-- Test: mutation mode detects success and hands off
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  local traitList = M.traitListFor("mutation")
  local activeT, inactiveT = makeAlleles(traitList, { species = { name = "NewSpecies" } })
  world.agentInventory[9] = mockBeeStack(activeT, inactiveT, true)

  local config = { workingSlots = { 9 } }
  local site = { name = "mutation-site", side = 4, mode = "mutation", targetSpecies = "NewSpecies" }
  local status = M.runMutationSite(config, site)
  check("runMutationSite detects a targetSpecies bee already in hand", status == "mutation_succeeded:switch_site_to_species_mode", status)
end

-- ============================================================
-- Test: analyzeWorkingSlots only analyzes unanalyzed bees
-- ============================================================

do
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false) -- unanalyzed
  world.agentInventory[2] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)  -- already analyzed

  local config = { workingSlots = { 1, 2 }, honeySlot = 20 }
  local analyzed = M.analyzeWorkingSlots(config)
  check("analyzeWorkingSlots analyzes exactly the unanalyzed one", analyzed == 1, "analyzed=" .. tostring(analyzed))
  check("analyzeWorkingSlots left the already-analyzed one alone (1 total call)", world.analyzeCalls == 1)
end

-- ============================================================
-- Test: harvestSite pulls product slots into empty working slots
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  apiary(2)[7] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)
  apiary(2)[8] = mockBeeStack({ fertility = 3 }, { fertility = 3 }, true)

  local config = { workingSlots = { 1, 2, 3 }, productSlots = { 7, 8 } }
  local site = { name = "harvest-site", side = 2, mode = "traitmax" }
  local harvested = M.harvestSite(config, site)
  check("harvestSite pulls both waiting products", harvested == 2, "harvested=" .. tostring(harvested))
  check("harvestSite clears the apiary's product slots", apiary(2)[7] == nil and apiary(2)[8] == nil)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
