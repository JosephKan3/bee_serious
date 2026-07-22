--[[
  Unit tests for bee_storage.lua. The shared-chest backend runs against an
  in-memory fake chest + cargo (same dependency-injection idea as the manager
  test's mocked world); the AE2 backend runs against a fake me_interface.
--]]

local Storage = require("bee_storage")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local function beeStack(name, species)
  return { name = name, size = 1, individual = { active = { species = { name = species } }, isAnalyzed = true } }
end

-- ============================================================
-- Shared-chest backend against an in-memory fake
-- ============================================================

-- Fake world: an external chest (array of slots) and cargo (map slot->stack).
local function makeFake()
  local chest = {}
  local cargo = {}
  local arrived = 0
  local deps = {
    arrive = function() arrived = arrived + 1; return true end,
    size = function() return 12 end,
    peek = function(slot) return chest[slot] end,
    pull = function(slot, cargoSlot, n)
      local s = chest[slot]
      if not s then return 0 end
      cargo[cargoSlot] = s
      chest[slot] = nil
      return 1
    end,
    push = function(cargoSlot, slot)
      local s = cargo[cargoSlot]
      if not s then return false end
      chest[slot] = s
      cargo[cargoSlot] = nil
      return true
    end,
  }
  return { chest = chest, cargo = cargo, deps = deps, arrivedCount = function() return arrived end }
end

do
  local f = makeFake()
  f.chest[2] = beeStack("Forestry:beePrincessGE", "Forest")
  f.chest[5] = beeStack("Forestry:beeDroneGE", "Meadows")
  f.chest[7] = { name = "forestry:honey_drop", size = 64 } -- not a bee

  local b = Storage.sharedChest(f.deps)
  check("sharedChest kind", b.kind == "shared")

  local snap = b:snapshot()
  check("snapshot returns exactly the two bees, skipping honey", #snap == 2, "got " .. #snap)
  local refs = {}
  for _, e in ipairs(snap) do refs[e.ref] = e.stack end
  check("snapshot carries the princess with its ref (slot 2)",
    refs[2] ~= nil and refs[2].name:find("Princess"))
  check("snapshot carries the drone with its ref (slot 5)",
    refs[5] ~= nil and refs[5].name:find("Drone"))

  check("fetch moves the princess into a cargo slot", b:fetch(2, 9))
  check("...cargo slot 9 now holds her", f.cargo[9] ~= nil and f.cargo[9].name:find("Princess"))
  check("...and the chest slot 2 is empty now", f.chest[2] == nil)

  -- deposit a cargo bee back into the first empty chest slot (1, since 2 is now free too -> 1 first)
  f.cargo[3] = beeStack("Forestry:beeDroneGE", "Wintry")
  check("deposit moves a cargo bee into the chest", b:deposit(3))
  local deposited = false
  for _, s in pairs(f.chest) do if s.name:find("Drone") and s.individual.active.species.name == "Wintry" then deposited = true end end
  check("...the Wintry drone is now somewhere in the chest", deposited)
  check("...and left the cargo slot", f.cargo[3] == nil)
end

do
  -- arrive() failing means no travel, empty snapshot, failed moves.
  local deps = {
    arrive = function() return false end,
    size = function() return 12 end,
    peek = function() return nil end,
    pull = function() return 1 end,
    push = function() return true end,
  }
  local b = Storage.sharedChest(deps)
  check("snapshot empty when arrive() fails", #b:snapshot() == 0)
  check("fetch false when arrive() fails", b:fetch(1, 2) == false)
  check("deposit false when arrive() fails", b:deposit(2) == false)
end

-- ============================================================
-- Factory dispatch
-- ============================================================

do
  local f = makeFake()
  local shared = Storage.new({ storageBackend = "shared" }, f.deps)
  check("factory builds shared backend", shared.kind == "shared")

  local shared2 = Storage.new({}, f.deps) -- default
  check("factory defaults to shared", shared2.kind == "shared")

  local ok = pcall(function() Storage.new({ storageBackend = "nope" }) end)
  check("factory errors on unknown backend", not ok)
end

-- ============================================================
-- AE2 backend read side against a fake me_interface
-- ============================================================

do
  local fakeItems = {
    { name = "Forestry:beePrincessGE", label = "Forest Princess", size = 1, individual = { active = { species = { name = "Forest" } } } },
    { name = "Forestry:beeDroneGE", label = "Meadows Drone", size = 3, individual = { active = { species = { name = "Meadows" } } } },
    { name = "gregtech:meta_item", label = "Circuit", size = 64 }, -- not a bee
  }
  local me = { getItemsInNetwork = function() return fakeItems end }
  local b = Storage.ae2({ me = function() return me end })
  check("ae2 kind", b.kind == "ae2")

  local snap = b:snapshot()
  check("ae2 snapshot lists the two bees, skipping the circuit", #snap == 2, "got " .. #snap)
  check("ae2 ref carries a network descriptor (name/label)",
    snap[1].ref.name ~= nil and snap[1].ref.label ~= nil)

  check("ae2 fetch errors clearly (Phase 4 not built)", not pcall(function() b:fetch(snap[1].ref, 1) end))
  check("ae2 deposit errors clearly (Phase 4 not built)", not pcall(function() b:deposit(1) end))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
