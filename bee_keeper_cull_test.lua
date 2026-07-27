--[[
  Unit test for M.cullBankedHybrids -- the anti-hoarding sweep.
  Policy (recommended): once a species has a full purebred bank (>= minDrones
  pure drones), trash its hybrid DRONES and its IGNOBLE (isNatural==false) hybrid
  princesses, from BOTH cargo and storage. Keep purebred bees, PRISTINE hybrid
  princesses (renewable / fix-fodder), and every bee of a not-yet-banked species.
]]

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Build a fresh, reset sim world seeded with a genebank config + the fixture
-- bees. `commonBanked` decides whether the 8 pure Common drones (the bank) are
-- seeded, so we can test both the banked and not-yet-banked gate.
local function setup(commonBanked)
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

  local prim = world.storage
  if commonBanked then put(prim, 1, pureRaw("Common"), "drone", 8) end -- the bank
  put(prim, 2, pureRaw("Common"), "princess", 1)                      -- pure princess (keep)
  put(prim, 3, hybridRaw("Common", "Forest", true), "drone", 5)       -- banked hybrid drone -> trash
  put(prim, 4, hybridRaw("Common", "Forest", false), "princess", 1)   -- ignoble hyb princess -> trash
  put(prim, 5, hybridRaw("Common", "Forest", true), "princess", 1)    -- PRISTINE hyb princess (keep)
  put(prim, 6, hybridRaw("Forest", "Meadows", true), "drone", 4)      -- non-banked hybrid (keep)
  put(world.storages[2].slots, 1, pureRaw("Common"), "princess", 1)   -- pure princess, 2nd store (keep)
  put(world.drone.inventory, 2, hybridRaw("Common", "Forest", true), "drone", 3) -- cargo banked hyb drone -> trash
  put(world.drone.inventory, 3, pureRaw("Common"), "drone", 2)        -- cargo pure drone (keep)

  require("bee_keeper_nav").setHome(70)
  return config, world, M
end

-- Count surviving bees across storage + cargo by a compact genotype/role key.
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

-- ---- banked: the redundant hybrids get voided, everything else survives ----
do
  local config, world, M = setup(true)
  M.scanStorageCensus(config)
  check("Common is banked (>= minDrones pure drones)", M.isSpeciesBanked(config, "Common"))
  check("Forest is NOT banked", not M.isSpeciesBanked(config, "Forest"))

  local voided = M.cullBankedHybrids(config)
  check("cull voided the 3 redundant stacks", voided == 3, "voided=" .. tostring(voided))

  local n = census(world)
  check("banked hybrid DRONES trashed (cargo + storage)", (n["Common/Forest|hyb|drone|nat=true"] or 0) == 0)
  check("IGNOBLE hybrid princess trashed", (n["Common/Forest|hyb|princess|nat=false"] or 0) == 0)
  check("PRISTINE hybrid princess kept", (n["Common/Forest|hyb|princess|nat=true"] or 0) == 1)
  check("pure drones kept (the bank untouched)", (n["Common/Common|pure|drone|nat=true"] or 0) == 10)
  check("pure princesses kept", (n["Common/Common|pure|princess|nat=true"] or 0) == 2)
  check("non-banked (Forest) hybrid drone kept as fodder", (n["Forest/Meadows|hyb|drone|nat=true"] or 0) == 4)
end

-- ---- not banked: the gate preserves EVERYTHING (nothing redundant yet) ----
do
  local config, world, M = setup(false)
  M.scanStorageCensus(config)
  check("Common NOT banked without the drone bank", not M.isSpeciesBanked(config, "Common"))

  local voided = M.cullBankedHybrids(config)
  check("cull voids nothing before anything is banked", voided == 0, "voided=" .. tostring(voided))

  local n = census(world)
  check("Common hybrid drones preserved (still fodder)", (n["Common/Forest|hyb|drone|nat=true"] or 0) == 8)
  check("ignoble hybrid princess preserved (still fodder)", (n["Common/Forest|hyb|princess|nat=false"] or 0) == 1)
end

print("")
if failures == 0 then print("ALL TESTS PASSED") else print(failures .. " TEST(S) FAILED"); os.exit(1) end
