--[[
  Mock-based tests for bee_keeper_manager.lua.

  There's no OpenComputers/Minecraft runtime to test against here, so this
  fakes "component", "sides", and "bee_keeper_nav" (the only hardware-
  touching requires) with an in-memory simulated world: a table of apiary
  slots keyed by (droneX, droneZ, side) -- mirroring how the real
  UpgradeBeekeeperUtil resolves position.offset(facing) from wherever the
  agent currently is -- plus a table of the agent's own inventory slots.
  bee_keeper_manager's actual decision logic (which drone to pick, which
  mutation pair to load, etc.) runs for real against these fakes -- only
  world I/O and flight are simulated, not the logic being tested. Nav's
  own geometry (orderByProximity, gotoXZ arrival/stuck detection) is
  tested separately in bee_keeper_nav_test.lua against the real module.
--]]

-- ============================================================
-- Fakes: sides, component, bee_keeper_nav
-- ============================================================

package.loaded["sides"] = {
  north = 2, south = 3, east = 4, west = 5, up = 0, down = 1,
}
local DOWN = 1

local world = {
  apiaries = {},  -- ["x:z:side"] = { [slot] = stack }
  agentInventory = {},  -- [slot] = stack
  selectedSlot = 1,
  analyzeCalls = 0,
  dronePos = { x = 0, z = 0 },
}

local function apiary(side)
  local key = world.dronePos.x .. ":" .. world.dronePos.z .. ":" .. side
  world.apiaries[key] = world.apiaries[key] or {}
  return world.apiaries[key]
end

-- Fake nav: instantly "arrives" and tracks position for apiary() to key
-- off of. Real Nav geometry (proximity ordering, stuck detection) is
-- tested against the real module in bee_keeper_nav_test.lua.
package.loaded["bee_keeper_nav"] = {
  setHome = function() end,
  setAltitude = function() return true end,
  getPos = function() return { x = world.dronePos.x, z = world.dronePos.z } end,
  gotoXZ = function(x, z) world.dronePos = { x = x, z = z }; return true end,
  gotoHome = function() world.dronePos = { x = 0, z = 0 }; return true end,
  orderByProximity = function(sites) return sites end, -- keep list order for test determinism
  needCharge = function() return false end,
  isFullyCharged = function() return true end,
  chargeAtHome = function() end,
}

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
  -- M.harvestSite queries this to guard against slot numbers beyond a real
  -- inventory's actual size (see its header notes) -- 15 is "big enough"
  -- for this test's fixtures, same reasoning as bee_keeper_sim.lua's fake.
  getInventorySize = function(_side) return 15 end,
  getStackInInternalSlot = function(slot)
    return world.agentInventory[slot]
  end,
  getStackInSlot = function(side, slot)
    return apiary(side)[slot]
  end,
  -- Lands in the CURRENTLY SELECTED slot, same as dropIntoSlot/swapQueen/
  -- swapDrone below -- NOT an auto-picked empty slot. This is what caught
  -- M.harvestSite forgetting to select() before calling this on real
  -- hardware: harvesting silently produced nothing.
  suckFromSlot = function(side, slot, count)
    local stack = apiary(side)[slot]
    if not stack then return 0 end
    if world.agentInventory[world.selectedSlot] ~= nil then return 0 end
    world.agentInventory[world.selectedSlot] = stack
    apiary(side)[slot] = nil
    return 1
  end,
  dropIntoSlot = function(side, slot)
    local stack = world.agentInventory[world.selectedSlot]
    if not stack then return false end
    apiary(side)[slot] = stack
    world.agentInventory[world.selectedSlot] = nil
    return true
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
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  -- Princess: good at everything except fertility.
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1 -- below the atLeast-4 target -> "bad"

  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  -- Working slot 5: a weak drone (nothing good).
  local weakActive, weakInactive = makeAlleles(traitList, {})
  world.agentInventory[5] = mockBeeStack(weakActive, weakInactive, true)

  -- Working slot 6: carries good fertility -- should be picked.
  local strongTraits = {}
  strongTraits.fertility = Cfg.targets.fertility.target
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[6] = mockBeeStack(strongActive, strongInactive, true)

  local config = { workingSlots = { 5, 6 }, minCopies = 2 }
  local site = { name = "test-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite reports a load", status:match("^loaded drone") ~= nil, status)
  check("runQualitySite selected slot 6 (fertility carrier)", world.selectedSlot == 6, "selected=" .. tostring(world.selectedSlot))
  check("runQualitySite actually swapped the drone into the apiary", apiary(DOWN)[2] ~= nil and apiary(DOWN)[2].individual.active.fertility == Cfg.targets.fertility.target)
  check("runQualitySite pulled the weak drone's slot back out (still slot 5 in inventory, untouched)", world.agentInventory[5] ~= nil)
end

-- ============================================================
-- Test: mutation mode matches held species against recipes and swaps in
-- the correct pair
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 20, z = 3 }
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
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports an attempt", status:match("^attempting mutation") ~= nil, status)
  check("runMutationSite loaded a queen", apiary(DOWN)[1] ~= nil)
  check("runMutationSite loaded a drone", apiary(DOWN)[2] ~= nil)

  local queenSpecies = Cfg.speciesKey(apiary(DOWN)[1].individual.active.species)
  local droneSpecies = Cfg.speciesKey(apiary(DOWN)[2].individual.active.species)
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
  world.dronePos = { x = 20, z = 3 }
  world._mutationRecipes = {
    ["NewSpecies"] = {
      { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
    },
  }
  local config = { workingSlots = { 3, 4 } }
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports waiting when parents aren't held", status:match("^waiting_on_parent_species") ~= nil, status)
end

-- ============================================================
-- Test: mutation mode detects success and hands off
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 20, z = 3 }
  local traitList = M.traitListFor("mutation")
  local activeT, inactiveT = makeAlleles(traitList, { species = { name = "NewSpecies" } })
  world.agentInventory[9] = mockBeeStack(activeT, inactiveT, true)

  local config = { workingSlots = { 9 } }
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }
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
  world.dronePos = { x = 5, z = 9 }
  apiary(DOWN)[7] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)
  apiary(DOWN)[8] = mockBeeStack({ fertility = 3 }, { fertility = 3 }, true)

  local config = { workingSlots = { 1, 2, 3 }, productSlots = { 7, 8 } }
  local site = { name = "harvest-site", x = 5, z = 9, mode = "traitmax" }
  local harvested = M.harvestSite(config, site)
  check("harvestSite pulls both waiting products", harvested == 2, "harvested=" .. tostring(harvested))
  check("harvestSite clears the apiary's product slots", apiary(DOWN)[7] == nil and apiary(DOWN)[8] == nil)
end

-- ============================================================
-- Test: without an explicit config.productSlots, harvestSite auto-derives
-- "every slot from 3 to the apiary's real size" -- this is exactly what
-- real hardware needed (product actually sits in slots 3-6 on a real
-- apiary, not 7-15, which was the old hardcoded guess).
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }
  apiary(DOWN)[3] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)
  apiary(DOWN)[5] = mockBeeStack({ fertility = 3 }, { fertility = 3 }, true)

  local config = { workingSlots = { 1, 2, 3 } } -- no productSlots override
  local site = { name = "harvest-site-auto", x = 5, z = 9, mode = "traitmax" }
  local harvested = M.harvestSite(config, site)
  check("harvestSite auto-derives product slots starting at 3, not 7",
    harvested == 2, "harvested=" .. tostring(harvested))
  check("harvestSite (auto-derived) clears the apiary's product slots",
    apiary(DOWN)[3] == nil and apiary(DOWN)[5] == nil)
end

-- ============================================================
-- Test: dumpToStorage flies to storagePos and drops discarded drones
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }
  world.agentInventory[10] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)
  world.agentInventory[11] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)

  local config = { storagePos = { x = 0, z = 0 }, storageSlotCount = 10 }
  local discardEntries = {
    { drone = { id = "a", _slot = 10 } },
    { drone = { id = "b", _slot = 11 } },
    { drone = { id = "keep-me", _slot = 12 } }, -- should be skipped (it's the kept one)
  }

  local dropped = M.dumpToStorage(config, discardEntries, "keep-me")
  check("dumpToStorage drops exactly the two non-kept drones", dropped == 2, "dropped=" .. tostring(dropped))
  check("dumpToStorage flew to storagePos", world.dronePos.x == 0 and world.dronePos.z == 0)
  check("dumpToStorage actually placed items in the storage inventory", apiary(DOWN)[1] ~= nil and apiary(DOWN)[2] ~= nil)
end

-- ============================================================
-- Test: loadSites merges persisted (x,z) with mode/targetSpecies overrides
-- ============================================================

do
  local saved = {
    { name = "site1", x = 3, z = 4 },
    { name = "site2", x = 10, z = 12 },
  }
  local overrides = {
    site2 = { mode = "species", targetSpecies = "Sticky" },
  }

  local sites = M.loadSites(saved, overrides)
  check("loadSites keeps positions", sites[1].x == 3 and sites[1].z == 4 and sites[2].x == 10 and sites[2].z == 12)
  check("loadSites defaults unassigned sites to traitmax", sites[1].mode == "traitmax")
  check("loadSites applies overrides", sites[2].mode == "species" and sites[2].targetSpecies == "Sticky")
end

-- ============================================================
-- Test: purityOf -- fraction of loci fixed to GG (progress to purebred)
-- ============================================================

do
  local traits = { "fertility", "speed", "lifespan", "flowering" }
  local function genotype(states)
    -- states: array of "GG" | "Gb" | "bb", one per trait above
    local g = {}
    for i, trait in ipairs(traits) do
      local s = states[i]
      g[trait] = {
        active = (s == "GG" or s == "Gb") and "good" or "bad",
        inactive = (s == "GG") and "good" or "bad",
      }
    end
    return g
  end

  check("purityOf: all GG is 1.0", M.purityOf(traits, genotype({ "GG", "GG", "GG", "GG" })) == 1.0)
  check("purityOf: none GG is 0.0", M.purityOf(traits, genotype({ "bb", "bb", "bb", "bb" })) == 0.0)
  check("purityOf: half GG is 0.5", M.purityOf(traits, genotype({ "GG", "GG", "bb", "bb" })) == 0.5)
  check("purityOf: heterozygous does NOT count as fixed",
    M.purityOf(traits, genotype({ "Gb", "Gb", "Gb", "Gb" })) == 0.0)
  check("purityOf: empty trait list doesn't divide by zero", M.purityOf({}, {}) == 0)
end

-- ============================================================
-- Test: runQualitySite caches purity onto the site for the dashboard
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 1, z = 1 }

  local traitList = M.traitListFor("traitmax")
  local allGood = {}
  for _, t in ipairs(traitList) do allGood[t] = Cfg.targets[t].target end
  local pActive, pInactive = makeAlleles(traitList, allGood)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)
  world.agentInventory[5] = mockBeeStack(pActive, pInactive, true)

  local site = { name = "purity-site", x = 1, z = 1, mode = "traitmax" }
  check("site has no progress before it's ever visited", site.progress == nil)

  M.runQualitySite({ workingSlots = { 5 }, minCopies = 2 }, site)
  check("runQualitySite records progress on the site", site.progress == 1.0,
    "progress=" .. tostring(site.progress))
end

-- ============================================================
-- Test: listCargo lists occupied working slots only, with raw stacks
-- (not just .individual -- the UI panel needs to show non-bee items too)
-- ============================================================

do
  world.agentInventory = {}
  world.agentInventory[2] = mockBeeStack({ fertility = 4 }, { fertility = 4 }, true)
  world.agentInventory[5] = { name = "forestry:honey_drop", size = 64 } -- non-bee item
  -- slot 3 deliberately left empty

  local config = { workingSlots = { 2, 3, 5, 9 } }
  local cargo = M.listCargo(config)
  check("listCargo returns exactly the occupied slots", #cargo == 2, "count=" .. #cargo)

  local bySlot = {}
  for _, entry in ipairs(cargo) do bySlot[entry.slot] = entry.stack end
  check("listCargo includes the bee stack", bySlot[2] ~= nil and bySlot[2].individual ~= nil)
  check("listCargo includes non-bee items too", bySlot[5] ~= nil and bySlot[5].name == "forestry:honey_drop")
  check("listCargo skips empty slots", bySlot[3] == nil and bySlot[9] == nil)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
