--[[
  Consistency test for the INCREMENTAL storage census (M.censusApplyStack).
  The whole point of the incremental cache is to avoid re-sweeping every store on
  each storage visit -- but only if the running cache stays EXACTLY what a fresh
  M.scanStorageCensus would produce. This drives real deposits + a removal and
  asserts the incrementally-updated cache == a full rescan, field for field.
]]

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local function setup()
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
  local function hybridRaw(a, i) local r = Sim.makeTemplateRaw(traitList, a, templates); r.species = { active = { name = a }, inactive = { name = i } }; r._natural = true; return r end
  local function put(store, slot, raw, kind, size) local st = Sim.toStack(raw, kind, true); st.size = size or 1; store[slot] = st end

  -- A mix across both stores: pures, carriers (V:/W:), various species.
  put(world.storage, 1, pureRaw("Common"), "drone", 8)
  put(world.storage, 2, pureRaw("Common"), "princess", 1)
  put(world.storage, 3, hybridRaw("Common", "Forest"), "drone", 5)
  put(world.storage, 4, hybridRaw("Forest", "Meadows"), "princess", 1)
  put(world.storages[2].slots, 1, pureRaw("Forest"), "drone", 8)
  put(world.storages[2].slots, 2, hybridRaw("Cultivated", "Common"), "drone", 3)

  require("bee_keeper_nav").setHome(70)
  return config, world, M, { pureRaw = pureRaw, hybridRaw = hybridRaw, toStack = Sim.toStack }
end

-- Deep-copy the census cache so a later full rescan (which overwrites it) can be
-- diffed against the incrementally-maintained version.
local function snapshotCache(config)
  local function copyCounts(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
  local summary = {}
  for sp, r in pairs(config._bankCensus or {}) do summary[sp] = { purePrincesses = r.purePrincesses, pureDrones = r.pureDrones } end
  -- slotsByKey reduced to a comparable set of "pos:slot" strings per key.
  local slots = {}
  for key, list in pairs(config._bankSlotsByKey or {}) do
    local set = {}
    for _, e in ipairs(list) do set[tostring(e.pos) .. ":" .. tostring(e.slot)] = true end
    slots[key] = set
  end
  return { summary = summary, conv = copyCounts(config._bankConvertible),
    convD = copyCounts(config._bankConvertibleDrones), slots = slots }
end

local function diff(a, b)
  local problems = {}
  local function cmpCounts(label, x, y)
    local keys = {}; for k in pairs(x) do keys[k] = true end; for k in pairs(y) do keys[k] = true end
    for k in pairs(keys) do if (x[k] or 0) ~= (y[k] or 0) then problems[#problems + 1] = string.format("%s[%s] %s vs %s", label, k, tostring(x[k]), tostring(y[k])) end end
  end
  local skeys = {}; for k in pairs(a.summary) do skeys[k] = true end; for k in pairs(b.summary) do skeys[k] = true end
  for sp in pairs(skeys) do
    local ra, rb = a.summary[sp] or {}, b.summary[sp] or {}
    if (ra.purePrincesses or 0) ~= (rb.purePrincesses or 0) then problems[#problems + 1] = "P[" .. sp .. "] " .. tostring(ra.purePrincesses) .. " vs " .. tostring(rb.purePrincesses) end
    if (ra.pureDrones or 0) ~= (rb.pureDrones or 0) then problems[#problems + 1] = "D[" .. sp .. "] " .. tostring(ra.pureDrones) .. " vs " .. tostring(rb.pureDrones) end
  end
  cmpCounts("V", a.conv, b.conv)
  cmpCounts("W", a.convD, b.convD)
  local kk = {}; for k in pairs(a.slots) do kk[k] = true end; for k in pairs(b.slots) do kk[k] = true end
  for key in pairs(kk) do
    local sa, sb = a.slots[key] or {}, b.slots[key] or {}
    for e in pairs(sa) do if not sb[e] then problems[#problems + 1] = "slot " .. key .. " has " .. e .. " (inc only)" end end
    for e in pairs(sb) do if not sa[e] then problems[#problems + 1] = "slot " .. key .. " missing " .. e .. " (fresh only)" end end
  end
  return problems
end

-- ---- deposits keep the cache == a fresh scan ----
do
  local config, world, M, mk = setup()
  M.scanStorageCensus(config) -- seed the cache

  -- Load cargo with bees to deposit: a new pure Common drone (merges into slot 1),
  -- a new pure species (Wintry) into a fresh slot, and a carrier.
  world.drone.inventory[2] = mk.toStack((function() local r = mk.pureRaw("Common"); return r end)(), "drone", true); world.drone.inventory[2].size = 4
  world.drone.inventory[3] = mk.toStack(mk.pureRaw("Wintry"), "princess", true); world.drone.inventory[3].size = 1
  world.drone.inventory[4] = mk.toStack(mk.hybridRaw("Common", "Forest"), "drone", true); world.drone.inventory[4].size = 2

  M.depositBeesAcrossStores(config, { { _slot = 2 }, { _slot = 3 }, { _slot = 4 } })
  local inc = snapshotCache(config)
  M.scanStorageCensus(config) -- fresh full rescan
  local fresh = snapshotCache(config)
  local problems = diff(inc, fresh)
  check("incremental cache == fresh scan after deposits", #problems == 0, table.concat(problems, "; "))
end

-- ---- a removal (fetch) keeps the cache == a fresh scan ----
do
  local config, world, M = setup()
  M.scanStorageCensus(config)

  -- Simulate a fetch of the whole carrier-drone stack at store 1 slot 3 (W:Common,
  -- W:Forest): physically empty it AND apply the incremental removal delta.
  local stack = world.storage[3]
  M.censusApplyStack(config, 1, 3, stack, stack.size, true, true)
  world.storage[3] = nil

  -- And a PARTIAL removal: pull 3 of the 8 pure Forest drones in store 2 slot 1.
  local st2 = world.storages[2].slots[1]
  M.censusApplyStack(config, 2, 1, st2, 3, true, false)
  st2.size = st2.size - 3

  local inc = snapshotCache(config)
  M.scanStorageCensus(config)
  local fresh = snapshotCache(config)
  local problems = diff(inc, fresh)
  check("incremental cache == fresh scan after full + partial removals", #problems == 0, table.concat(problems, "; "))
end

print("")
if failures == 0 then print("ALL TESTS PASSED") else print(failures .. " TEST(S) FAILED"); os.exit(1) end
