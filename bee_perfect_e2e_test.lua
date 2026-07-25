--[[
  PERFECT phase mechanic -- current behavior + KNOWN LIMITATION.

  The perfect phase runs species mode toward species X with the traitmax MAX bee
  (a DIFFERENT species, all traits good) as the allele donor, aiming for a bee
  that is BOTH species-pure X AND homozygous-good on every target trait.

  FINDING (this test): the donor's good alleles DO get bred into X (real
  progress), but naive species mode PLATEAUS well short of a fully-perfect X --
  species purity and trait-fixing are in tension when the only good-allele source
  is a foreign species (each cross toward X-pure with bad-X drones dilutes the
  good alleles; each cross with the donor re-contaminates the species). So this
  test asserts the progress that works and DOCUMENTS the plateau; achieving a
  full 9/9 X-pure-perfect needs a smarter per-species combine (e.g. first convert
  the allele set into an X-carrier bank, then homozygize within species X) --
  that algorithm is the open follow-up for the perfect phase.
--]]

package.path = package.path .. ";./?.lua"
math.randomseed(2024)

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local Cfg = require("bee_trait_config")
local Sim = require("bee_keeper_sim")

local TARGET = "Diligent"   -- the species to make perfect
local DONOR_SP = "Ended"    -- the max bee's (arbitrary) species
local traits = Cfg.activeTraits(); traits[#traits + 1] = "species"

local config = require("bee_keeper_manager_config")
config.mutationGraph = nil
config.genebank = nil
config.program = nil
config.templates = nil
config.sites = {}
local pos = { { x = 4, z = 3 }, { x = -3, z = 6 }, { x = 8, z = -5 } }
for i = 1, 3 do config.sites[i] = { name = "apiary" .. i, x = pos[i].x, z = pos[i].z, mode = "species", targetSpecies = TARGET } end
config.storagePos = { x = -6, z = -6 }
config.trashPos = { x = -8, z = -8 }
config.chargerPos = { x = 0, z = 0 }
config.workingSlots = {}; for s = 2, 32 do config.workingSlots[#config.workingSlots + 1] = s end

Sim.install(config, config.sites, { cargoSize = 32, storageSize = 512 })

-- Replace the auto-seeded (already-perfect) species population with a CONTROLLED
-- one: X purebred but all-BAD traits, plus a stack of all-GOOD donor drones of a
-- different species. The only good alleles come from the donor.
for _, slot in ipairs(config.workingSlots) do
  local st = Sim.world.drone.inventory[slot]
  if st and st.individual then Sim.world.drone.inventory[slot] = nil end
end
Sim.world.storage = {}

local function xBad(kind) return Sim.toStack(Sim.makeStartingRaw(traits, TARGET), kind, true) end
local function donor(kind) return Sim.toStack(Sim.makeGoodRaw(traits, DONOR_SP), kind, true) end

-- X princesses (the line to purify) + all-good donor drones, in cargo and storage.
local ci = 2
local function putCargo(stack) Sim.world.drone.inventory[config.workingSlots[ci]] = stack; ci = ci + 1 end
for _ = 1, 3 do putCargo(xBad("princess")) end
for _ = 1, 3 do putCargo(donor("drone")) end
local si = 1
local function putStore(stack) Sim.world.storage[si] = stack; si = si + 1 end
for _ = 1, 20 do putStore(xBad("princess")) end
for _ = 1, 20 do putStore(donor("drone")) end
-- a few good donor princesses too, so the line has a good-allele mother source
for _ = 1, 6 do putStore(donor("princess")) end

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)

local coverable = Cfg.activeTraits()
-- Best count of good traits among X-pure bees anywhere in the world.
local function bestXPureGood()
  local best = -1
  local function scan(stack)
    local ind = stack and stack.individual
    if not (ind and ind.active and ind.inactive) then return end
    if Cfg.speciesKey(ind.active.species) ~= TARGET or Cfg.speciesKey(ind.inactive.species) ~= TARGET then return end
    local g = 0
    for _, t in ipairs(coverable) do
      if Cfg.isGoodValue(t, ind.active[t]) and Cfg.isGoodValue(t, ind.inactive[t]) then g = g + 1 end
    end
    if g > best then best = g end
  end
  for _, a in pairs(Sim.world.apiaries) do
    for _, st in pairs(a.products or {}) do scan(st) end
    if a.princess then scan(a.princess) end
  end
  for _, st in pairs(Sim.world.storage or {}) do scan(st) end
  for _, st in pairs(Sim.world.drone.inventory or {}) do scan(st) end
  return best
end

check("no perfect-X bee at start (donor is a different species; X is all-bad)", bestXPureGood() <= 0)

local realprint = print; _G.print = function() end
for _ = 1, 400 do M.runCycle(config) end
_G.print = realprint

local reached = bestXPureGood()
-- The donor's alleles DO get bred into species-pure X (real progress) -- proving
-- the perfect-phase wiring reaches and uses the max donor. Full 9/9 convergence
-- is the documented open problem (see the header); assert the progress, not it.
check("perfect phase imbues donor alleles into species-pure " .. TARGET .. " (progress > 0)",
  reached >= 1, "best X-pure good = " .. reached .. "/" .. #coverable)
realprint(string.format("  (best species-pure %s reached %d/%d good traits in 400 cycles -- naive species-mode plateau; see header)",
  TARGET, reached, #coverable))

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
