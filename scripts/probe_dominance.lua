--[[
  Dominance / genome-shape probe.
  --------------------------------
  Goal: find out whether the OC Forestry API exposes each allele's
  DOMINANT/RECESSIVE flag (Forestry's IAllele.isDominant()). We need it to model
  species expression faithfully in the simulator -- a hybrid bee expresses its
  DOMINANT species allele, and that determines which of its two alleles reads as
  the "active" (primary) one. Our earlier dumps captured active/inactive VALUES
  but no dominance flag; this checks the full method surface + a full analyzed
  genome so we can see if it's reachable at all.

  SETUP: same stationary rig as scripts/dump_bee_data.lua -- an OC Adapter next
  to an apiary, with an ANALYZED bee (ideally a HYBRID, e.g. a Forest/Wintry
  from a failed mutation) sitting in the princess slot, so getQueen() returns a
  real two-allele genome to inspect. Run it and send back dominance_probe.log.
--]]

local component = require("component")
local ser = require("serialization")

local housing
for addr in component.list() do
  local ok, proxy = pcall(component.proxy, addr)
  if ok and proxy and proxy.getBeeBreedingData then housing = proxy end
end
if not housing then
  print("No bee-housing component found (nothing exposes getBeeBreedingData).")
  return
end

local out = io.open("dominance_probe.log", "w")
local function w(s) out:write(s .. "\n") end

-- 1) Every method/field on the housing proxy -- spot any dominance-related call
--    (getAllele*, isDominant, getTemplate, getGenome, ...).
w("== housing component methods/fields ==")
for k in pairs(housing) do w("  " .. tostring(k)) end

-- 2) A full listAllSpecies entry -- in case there are fields we didn't capture.
local species = housing.listAllSpecies()
w("\n== listAllSpecies()[1] (full) ==")
w(ser.serialize(species and species[1]))

-- 3) A full analyzed genome -- the whole active/inactive shape, to eyeball any
--    dominance/expressed markers. Needs an analyzed bee in the princess slot.
local ok, queen = pcall(function() return housing.getQueen() end)
w("\n== getQueen() (full genome) ==")
w(ser.serialize(ok and queen or ("<error: " .. tostring(queen) .. ">")))

local okD, drone = pcall(function() return housing.getDrone() end)
w("\n== getDrone() (full genome) ==")
w(ser.serialize(okD and drone or ("<error: " .. tostring(drone) .. ">")))

-- 4) If any obvious per-allele call exists, try it on the queen's species.
if housing.getBeeParents then
  w("\n== getBeeParents(<queen species>) sample ==")
  local sp = ok and queen and queen.ident
  w("queen ident: " .. tostring(sp))
end

out:close()
print("wrote dominance_probe.log -- send it back")
