--[[
  Honeydew is stored SEPARATELY from bees, in its own drawer (config.
  honeyStoragePos). This proves M.restockHoney pulls honeydew from that drawer
  into the analysis honey slot WITHOUT touching the bee storage -- the two are
  kept fully separate.
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
config.needCharge = false
config.chargerPos = { x = 0, z = 0 }
config.trashPos = nil
config.honeySlot = 1
config.honeyCount = nil
-- Bee storage (one chest) and the honeydew drawer at a DIFFERENT position.
config.storagePos = nil
config.storagePositions = { { x = -6, z = -6 } }
config.honeyStoragePos = { x = -9, z = -9 }
config.workingSlots = {}; for s = 2, 16 do config.workingSlots[#config.workingSlots + 1] = s end

Sim.install(config, config.sites, { cargoSize = 16, storageSizes = { 27 }, honeyDrawerStock = 64 })

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)

-- Put a bee (NOT honey) in the bee chest so we can prove restock never touches it.
Sim.world.storages[1].slots = {}
Sim.world.storage = Sim.world.storages[1].slots
Sim.world.storage[1] = Sim.toStack(Sim.makeStartingRaw(traits, "Forest"), "drone", true)

-- Honey slot (cargo slot 1) starts empty.
Sim.world.drone.inventory[config.honeySlot] = nil

local function drawerStock()
  local drawer
  for _, s in ipairs(Sim.world.storages) do
    if s.x == config.honeyStoragePos.x and s.z == config.honeyStoragePos.z then drawer = s end
  end
  local n = 0
  for _, st in pairs(drawer.slots) do n = n + (st.size or 0) end
  return n
end

local function looksHoney(st) return st and st.name and st.name:lower():find("honey") ~= nil end

check("drawer starts stocked with honeydew", drawerStock() == 64, "stock=" .. drawerStock())
check("honey slot starts empty", Sim.world.drone.inventory[config.honeySlot] == nil)

local realprint = print; _G.print = function() end
local ok = M.restockHoney(config)
_G.print = realprint

check("restockHoney reports success", ok == true)
local honey = Sim.world.drone.inventory[config.honeySlot]
check("honeydew landed in the analysis honey slot", looksHoney(honey), honey and honey.name or "nil")
check("it came FROM the drawer (drawer stock dropped)", drawerStock() < 64, "stock=" .. drawerStock())

-- Separation: the bee store was never touched -- the Forest drone is still there,
-- and no honey was ever put into it.
local beeStillThere, honeyInBeeStore = false, false
for _, st in pairs(Sim.world.storages[1].slots) do
  if st.individual and Cfg.speciesKey(st.individual.active.species) == "Forest" then beeStillThere = true end
  if looksHoney(st) then honeyInBeeStore = true end
end
check("bee storage untouched (the Forest drone is still there)", beeStillThere)
check("no honey was ever placed into bee storage", not honeyInBeeStore)

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
