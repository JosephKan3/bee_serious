--[[
  Unit test for M.cullBankedHybrids -- the anti-hoarding sweep.
  Policy: trash a hybrid ONLY once BOTH species it carries have a self-sustaining
  pure set (a pure princess AND a pure drone). Of those, trash hybrid DRONES and
  IGNOBLE (isNatural==false) hybrid princesses; keep PRISTINE hybrid princesses.
  Never touch purebred bees, or any hybrid carrying a species that lacks a pure
  set yet (it may be that species' only carrier). Applies to cargo AND storage.
]]

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Fresh, reset sim world + genebank config + fixture bees. `withPureSets` decides
-- whether Common AND Forest get pure princess+drone sets, so we can test both the
-- discardable case and the gate that preserves everything before a pure set exists.
local function setup(withPureSets)
  package.loaded["bee_keeper_manager_config"] = nil
  local config = require("bee_keeper_manager_config")
  config.honeySlot = 1
  config.workingSlots = {}
  for s = 2, 32 do config.workingSlots[#config.workingSlots + 1] = s end
  config.storagePositions = { { x = 0, z = -3 }, { x = 1, z = -3 } }
  config.storagePos = config.storagePositions[1]
  config.honeyStoragePos = { x = 0, z = -2 }
  config.trashPos = { x = 4, z = -3 }
  config.chargerPos = { x = 0, z = 0 }
  config.genebank = { minPrincesses = 1, minDrones = 8 }
  config.cullEveryVisits = 1 -- run the cull on every call (no throttle) for a deterministic test
  local sites = { { name = "site1", x = 2, z = -2, mode = "traitmax" } }
  config.sites = sites

  local Sim = require("bee_keeper_sim")
  Sim.install(config, sites, { cargoSize = 32, storageSize = 125, storageSizes = { 125, 125 }, honeyDrawerStock = 64 })
  local world = Sim.world
  local traitList = world.traitList
  local M = require("bee_keeper_manager")
  local templates = select(1, M.loadTemplates(config)); world.templates = templates

  world.drone.inventory = {}
  world.storage = {}
  for _, s in ipairs(world.storages) do if not s.primary and s.slots then s.slots = {} end end
  world.drone.x, world.drone.z, world.drone.facing, world.drone.energy = 0, 0, 1, 1.0
  world.drone._selected = nil

  local function pureRaw(sp) local r = Sim.makeTemplateRaw(traitList, sp, templates); r._natural = true; return r end
  local function hybridRaw(a, i, natural)
    local r = Sim.makeTemplateRaw(traitList, a, templates)
    r.species = { active = { name = a }, inactive = { name = i } }
    r._natural = natural
    return r
  end
  local function put(store, slot, raw, kind, size)
    local st = Sim.toStack(raw, kind, true); st.size = size or 1; store[slot] = st
  end

  local prim, store2 = world.storage, world.storages[2].slots
  if withPureSets then
    -- Pure sets (princess + drone) for BOTH Common and Forest -> both discardable.
    put(prim, 1, pureRaw("Common"), "drone", 8)
    put(prim, 2, pureRaw("Common"), "princess", 1)
    put(store2, 1, pureRaw("Forest"), "drone", 8)
    put(store2, 2, pureRaw("Forest"), "princess", 1)
  end
  put(prim, 3, hybridRaw("Common", "Forest", true), "drone", 5)     -- both pure -> TRASH
  put(prim, 4, hybridRaw("Common", "Forest", false), "princess", 1) -- ignoble    -> TRASH
  put(prim, 5, hybridRaw("Common", "Forest", true), "princess", 1)  -- PRISTINE   -> KEEP
  put(prim, 6, hybridRaw("Common", "Meadows", true), "drone", 4)    -- Meadows unbanked -> KEEP
  put(world.drone.inventory, 2, hybridRaw("Common", "Forest", true), "drone", 3) -- cargo -> TRASH
  put(world.drone.inventory, 3, pureRaw("Common"), "drone", 2)      -- pure       -> KEEP

  require("bee_keeper_nav").setHome(70)
  return config, world, M
end

local function census(world)
  local n = {}
  local function tally(stack)
    if not stack or not stack.individual then return end
    local ind = stack.individual
    local a, i = ind.active.species.name, ind.inactive.species.name
    local role = stack.name:lower():find("drone") and "drone" or "princess"
    local key = string.format("%s/%s|%s|%s|nat=%s", a, i, (a == i) and "pure" or "hyb", role, tostring(ind.isNatural))
    n[key] = (n[key] or 0) + (stack.size or 1)
  end
  for _, st in pairs(world.storage) do tally(st) end
  for _, s in ipairs(world.storages) do if s.slots then for _, st in pairs(s.slots) do tally(st) end end end
  for _, st in pairs(world.drone.inventory) do tally(st) end
  return n
end

-- ---- both species have a pure set: redundant hybrids voided, rest survives ----
do
  local config, world, M = setup(true)
  M.scanStorageCensus(config)
  check("Common has a pure set", M.speciesHasPureSet(config, "Common"))
  check("Forest has a pure set", M.speciesHasPureSet(config, "Forest"))
  check("Meadows has NO pure set", not M.speciesHasPureSet(config, "Meadows"))

  local voided = M.cullBankedHybrids(config)
  check("cull voided the 3 redundant stacks", voided == 3, "voided=" .. tostring(voided))

  local n = census(world)
  check("Common/Forest hybrid DRONES trashed (cargo + storage)", (n["Common/Forest|hyb|drone|nat=true"] or 0) == 0)
  check("IGNOBLE Common/Forest princess trashed", (n["Common/Forest|hyb|princess|nat=false"] or 0) == 0)
  check("PRISTINE Common/Forest princess kept", (n["Common/Forest|hyb|princess|nat=true"] or 0) == 1)
  check("Common/Meadows hybrid kept (Meadows has no pure set)", (n["Common/Meadows|hyb|drone|nat=true"] or 0) == 4)
  check("pure Common bees kept", (n["Common/Common|pure|drone|nat=true"] or 0) == 10
    and (n["Common/Common|pure|princess|nat=true"] or 0) == 1)
  check("pure Forest bank kept", (n["Forest/Forest|pure|drone|nat=true"] or 0) == 8)
end

-- ---- no pure set yet: the gate preserves EVERYTHING ----
do
  local config, world, M = setup(false)
  M.scanStorageCensus(config)
  check("nothing discardable before a pure set exists", not M.speciesHasPureSet(config, "Common"))

  local voided = M.cullBankedHybrids(config)
  check("cull voids nothing before a pure set exists", voided == 0, "voided=" .. tostring(voided))

  local n = census(world)
  check("Common/Forest hybrid drones preserved as fodder", (n["Common/Forest|hyb|drone|nat=true"] or 0) == 8)
  check("ignoble hybrid princess preserved as fodder", (n["Common/Forest|hyb|princess|nat=false"] or 0) == 1)
end

print("")
if failures == 0 then print("ALL TESTS PASSED") else print(failures .. " TEST(S) FAILED"); os.exit(1) end
