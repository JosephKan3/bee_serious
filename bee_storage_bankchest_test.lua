--[[
  Test for the DEDICATED BANK CHEST (v0.7.2): a subset of the storage network
  reserved for the inviolable purebred reserve. Deposit tops the bank up to the
  per-species reserve (minPrincesses + minDrones) FIRST; every surplus pure and
  every hybrid goes to the WORKING stores. The census tags bank slots so the
  climb's fetch skips them (only `grow` may draw the bank pair).

  Driven against the real manager + sim, same harness as bee_storage_multichest_test.
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
config.mutationGraph = nil; config.program = nil; config.templates = nil
config.sites = {}
config.storagePos = nil
-- Store 1 = the dedicated BANK; stores 2 & 3 = working. Reserve = 1 princess + 2 drones.
config.storagePositions = { { x = -6, z = -6 }, { x = -6, z = -8 }, { x = -6, z = -10 } }
config.bankStoragePositions = { { x = -6, z = -6 } }
config.genebank = { minPrincesses = 1, minDrones = 2 }
config.chargerPos = { x = 0, z = 0 }
config.trashPos = nil
config.needCharge = false
config.workingSlots = {}; for s = 2, 32 do config.workingSlots[#config.workingSlots + 1] = s end
config.onStorageFull = function() end

Sim.install(config, config.sites, { cargoSize = 32, storageSizes = { 12, 12, 12 } })

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)

-- A pure (species-homozygous) bee of `species`.
local function pure(species, kind) return Sim.toStack(Sim.makeStartingRaw(traits, species), kind, true) end
-- A hybrid drone carrying `a` (active) + `b` (inactive).
local function hybrid(a, b, kind)
  local raw = Sim.makeStartingRaw(traits, a)
  raw.species = { active = { name = a, uid = "sim." .. a:lower() }, inactive = { name = b, uid = "sim." .. b:lower() } }
  return Sim.toStack(raw, kind, true)
end

-- Classify every occupied slot of a store into { princesses, drones } per species,
-- summing stack sizes (pure drones stack, so slot count != bee count).
local function countStore(i)
  local out = {}
  for _, st in pairs(Sim.world.storages[i].slots) do
    local ind = st.individual
    if ind and ind.active and ind.active.species and ind.inactive and ind.inactive.species then
      local a, b = ind.active.species.name, ind.inactive.species.name
      local pureBee = (a == b)
      local role = st.name:lower():find("princess") and "princess" or "drone"
      out[a] = out[a] or { pP = 0, pD = 0, hyb = 0 }
      if pureBee and role == "princess" then out[a].pP = out[a].pP + (st.size or 1)
      elseif pureBee then out[a].pD = out[a].pD + (st.size or 1)
      else out[a].hyb = out[a].hyb + (st.size or 1) end
    end
  end
  return out
end

local function seedCargo(stacks)
  for _, slot in ipairs(config.workingSlots) do Sim.world.drone.inventory[slot] = nil end
  local entries = {}
  for i, st in ipairs(stacks) do
    local slot = config.workingSlots[i]
    Sim.world.drone.inventory[slot] = st
    entries[#entries + 1] = { drone = { id = "e" .. slot, _slot = slot } }
  end
  return entries
end

-- ============================================================
-- Deposit routing: pures top the bank to reserve, surplus + hybrids go working.
-- ============================================================
do
  for i = 1, 3 do Sim.world.storages[i].slots = {} end
  Sim.world.storage = Sim.world.storages[1].slots

  -- 1 pure Forest princess, 4 pure Forest drones, 1 Forest/Meadows hybrid drone.
  local entries = seedCargo({
    pure("Forest", "princess"),
    pure("Forest", "drone"), pure("Forest", "drone"),
    pure("Forest", "drone"), pure("Forest", "drone"),
    hybrid("Forest", "Meadows", "drone"),
  })
  local dropped = M.dumpToStorage(config, entries, nil)
  check("routing: every bee deposited (nothing stranded)", dropped == 6, "dropped=" .. dropped)

  local bank = countStore(1)
  local w2, w3 = countStore(2), countStore(3)
  local workDrones = (w2.Forest and w2.Forest.pD or 0) + (w3.Forest and w3.Forest.pD or 0)
  local workHyb = (w2.Forest and w2.Forest.hyb or 0) + (w3.Forest and w3.Forest.hyb or 0)

  check("routing: bank holds EXACTLY the princess reserve (1)", (bank.Forest and bank.Forest.pP or 0) == 1,
    "bank pP=" .. (bank.Forest and bank.Forest.pP or 0))
  check("routing: bank holds EXACTLY the drone reserve (2), never more", (bank.Forest and bank.Forest.pD or 0) == 2,
    "bank pD=" .. (bank.Forest and bank.Forest.pD or 0))
  check("routing: the 2 SURPLUS drones went to the working stores", workDrones == 2, "work pD=" .. workDrones)
  check("routing: the hybrid drone went to a working store, never the bank", workHyb == 1 and (bank.Forest and bank.Forest.hyb or 0) == 0,
    "work hyb=" .. workHyb .. " bank hyb=" .. (bank.Forest and bank.Forest.hyb or 0))
end

-- ============================================================
-- Census tagging: bank slots carry bank=true; working slots don't. The fetch
-- pick() consumes this flag to keep the climb off the reserve.
-- ============================================================
do
  local _, _, slotsByKey = M.scanStorageCensus(config)

  local function hasBank(key)
    local anyBank, anyWorking = false, false
    for _, e in ipairs(slotsByKey[key] or {}) do
      if e.bank then anyBank = true else anyWorking = true end
    end
    return anyBank, anyWorking
  end

  local pB, _ = hasBank("P:Forest")
  check("census: the reserve princess slot is tagged bank=true", pB)

  local dB, dW = hasBank("D:Forest")
  check("census: D:Forest has a bank-tagged reserve slot", dB)
  check("census: D:Forest ALSO has a working (surplus) slot the climb can spend", dW)

  -- Hybrid drone -> W: carrier of both alleles, all in working (never bank).
  local wB = false
  for _, e in ipairs(slotsByKey["W:Meadows"] or {}) do if e.bank then wB = true end end
  check("census: hybrid carrier slots are never bank-tagged", not wB)
end

-- ============================================================
-- No bank configured -> unchanged whole-network fill (regression guard).
-- ============================================================
do
  local cfg2 = { storagePositions = { { x = 1, z = 1 }, { x = 2, z = 2 } } }
  check("isBankStore false when no bank configured", not M.isBankStore(cfg2, 1))
  check("workingStorageEntries returns the whole network when no bank set", #M.workingStorageEntries(cfg2) == 2)
  config.bankStoragePositions = { { x = -6, z = -6 } }
  check("isBankStore true for the configured bank position", M.isBankStore(config, 1))
  check("isBankStore false for a working position", not M.isBankStore(config, 2))
  check("workingStorageEntries excludes the bank store", #M.workingStorageEntries(config) == 2
    and M.workingStorageEntries(config)[1].index == 2)
end

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
