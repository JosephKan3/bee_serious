--[[
  End-to-end test for MULTI-CHEST apiarist storage (the AE2 replacement).

  The robot flies between several apiarist chests, filling one before spilling
  into the next (M.dumpToStorage). When EVERY chest is full and a bee still has
  nowhere to go, it halts and beeps (M.onStorageFull) instead of dropping bees.

  Driven against the real manager + sim, with the sim extended to model one
  bounded chest per config.storagePositions entry.
--]]

package.path = package.path .. ";./?.lua"

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local Cfg = require("bee_trait_config")
local Sim = require("bee_keeper_sim")

local traits = {}; for _, t in ipairs(Cfg.activeTraits()) do traits[#traits + 1] = t end
traits[#traits + 1] = "species"

local config = require("bee_keeper_manager_config")
config.mutationGraph = nil; config.genebank = nil; config.program = nil; config.templates = nil
config.sites = {}
config.storagePos = nil
-- Three small apiarist chests (3 slots each) so we can fill them deterministically.
config.storagePositions = { { x = -6, z = -6 }, { x = -6, z = -8 }, { x = -6, z = -10 } }
config.chargerPos = { x = 0, z = 0 }
config.trashPos = nil
config.needCharge = false
config.workingSlots = {}; for s = 2, 32 do config.workingSlots[#config.workingSlots + 1] = s end

Sim.install(config, config.sites, { cargoSize = 32, storageSizes = { 3, 3, 3 } })

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)

-- Distinct-species drones so each takes its own storage slot (different genomes
-- don't stack), giving us exact per-chest slot accounting.
-- Distinct species so every bee is a different genome -> no stacking, exact
-- per-slot accounting (identical drones would otherwise merge into one slot).
local SPECIES = {
  "Forest", "Meadows", "Modest", "Wintry", "Marshy", "Tropical", "Rocky", "Ocean",
  "Common", "Sorcerous", "Unusual", "Valiant", "Steadfast", "Cultivated", "Noble",
}
local function seedCargo(n, offset)
  offset = offset or 0
  for _, slot in ipairs(config.workingSlots) do Sim.world.drone.inventory[slot] = nil end
  local entries = {}
  for i = 1, n do
    local slot = config.workingSlots[i]
    Sim.world.drone.inventory[slot] = Sim.toStack(Sim.makeStartingRaw(traits, SPECIES[offset + i]), "drone", true)
    entries[#entries + 1] = { drone = { id = slot, _slot = slot } }
  end
  return entries
end
local function chestFill(i)
  local n = 0
  for _ in pairs(Sim.world.storages[i].slots) do n = n + 1 end
  return n
end
local function cargoBees()
  local n = 0
  for _, slot in ipairs(config.workingSlots) do
    if Sim.world.drone.inventory[slot] then n = n + 1 end
  end
  return n
end

-- ============================================================
-- Spillover: fill chest 1, spill the rest into chest 2, none lost, no halt.
-- ============================================================
do
  for i = 1, 3 do Sim.world.storages[i].slots = {} end
  Sim.world.storage = Sim.world.storages[1].slots
  local fullFired = false
  config.onStorageFull = function() fullFired = true end

  local entries = seedCargo(5) -- 5 bees, chests hold 3 each
  local dropped = M.dumpToStorage(config, entries, nil)

  check("spillover: all 5 bees deposited", dropped == 5, "dropped=" .. dropped)
  check("spillover: chest 1 filled to its 3 slots", chestFill(1) == 3, "chest1=" .. chestFill(1))
  check("spillover: remaining 2 spilled into chest 2", chestFill(2) == 2, "chest2=" .. chestFill(2))
  check("spillover: chest 3 untouched", chestFill(3) == 0, "chest3=" .. chestFill(3))
  check("spillover: cargo emptied", cargoBees() == 0, "cargo=" .. cargoBees())
  check("spillover: NO storage-full halt (there was room)", not fullFired)
end

-- ============================================================
-- All full: chests hold 9 total; deposit 12; 9 land, 3 have nowhere to go ->
-- M.onStorageFull fires with exactly those 3 pending.
-- ============================================================
do
  for i = 1, 3 do Sim.world.storages[i].slots = {} end
  Sim.world.storage = Sim.world.storages[1].slots
  local pendingSeen = nil
  config.onStorageFull = function(_cfg, pending) pendingSeen = pending end

  local entries = seedCargo(9) -- exactly fills all three 3-slot chests
  local dropped = M.dumpToStorage(config, entries, nil)
  check("all-full setup: 9 bees fill every chest", dropped == 9 and chestFill(1) == 3 and chestFill(2) == 3 and chestFill(3) == 3,
    string.format("dropped=%d c1=%d c2=%d c3=%d", dropped, chestFill(1), chestFill(2), chestFill(3)))
  check("all-full setup: no halt yet (they all fit)", pendingSeen == nil)

  -- Now every chest is full; deposit 3 MORE distinct bees (species 10-12, none
  -- already stored, so they can't stack into an existing slot) -> all 3 overflow.
  local more = seedCargo(3, 9)
  -- shift the 3 new entries onto fresh slots so they don't collide with the
  -- already-deposited ones (seedCargo clears cargo first, so slots 2..4 are the
  -- new bees).
  local dropped2 = M.dumpToStorage(config, more, nil)
  check("all-full: nothing more could be deposited", dropped2 == 0, "dropped2=" .. dropped2)
  check("all-full: M.onStorageFull fired", pendingSeen ~= nil)
  check("all-full: it reported exactly the 3 stranded bees", pendingSeen and #pendingSeen == 3,
    "pending=" .. (pendingSeen and #pendingSeen or "nil"))
  check("all-full: stranded bees remain in cargo (not dropped on the floor)", cargoBees() == 3, "cargo=" .. cargoBees())
end

-- ============================================================
-- Fallback: no storagePositions -> single legacy storagePos still works.
-- ============================================================
do
  check("storagePositions() prefers the multi-chest list",
    #M.storagePositions({ storagePositions = { { x = 1, z = 1 }, { x = 2, z = 2 } } }) == 2)
  check("storagePositions() falls back to single storagePos",
    #M.storagePositions({ storagePos = { x = 5, z = 5 } }) == 1)
  check("storagePositions() empty when neither set", #M.storagePositions({}) == 0)
end

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
