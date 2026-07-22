--[[
  Bee data dumper for the bee_serious project.
  -------------------------------------------------
  Regenerates bee_mutations.dat / bee_species.dat (and optionally
  queen_genome.dat) from the LIVE game -- re-run this after a GTNH version bump
  to refresh the mutation graph the planner depends on. See
  docs/oc_forestry_api.md for the data shapes and the whole rationale.

  SETUP (one-time, stationary -- NOT the breeding robot):
    - Place an OpenComputers Adapter block directly touching a Forestry apiary
      (or alveary / bee house / industrial apiary).
    - Attach an OC Computer + Screen + Keyboard to that Adapter (adjacency or
      cable). No internet card needed.
    - (Optional) put an ANALYZED queen in the apiary to also dump a genome
      template (feeds the traitmax species->template map).

  RUN:  copy this file onto that stationary computer and run it, e.g.
        `dump_bee_data`  (or `lua dump_bee_data.lua`).
  Then copy the produced .dat files into the bee_serious repo, replacing the
  committed ones, and commit.

  The apiary housing component is registered under a tile-derived name in this
  OC build (observed: `tile_for_apiculture_0_name`), NOT "bee_housing" -- and
  that name could differ in another version -- so this discovers the component
  by CAPABILITY (has getBeeBreedingData) rather than a hardcoded type string.
--]]

local component = require("component")
local ser = require("serialization")

local function findHousing()
  for addr, ctype in component.list() do
    local ok, proxy = pcall(component.proxy, addr)
    if ok and proxy and proxy.getBeeBreedingData then
      return proxy, ctype
    end
  end
  return nil
end

local housing, ctype = findHousing()
if not housing then
  print("No bee-housing component found (nothing exposes getBeeBreedingData).")
  print("Place an OC Adapter directly next to an apiary/alveary, connect it to")
  print("this computer, and re-run.  `components`: ")
  for addr, t in component.list() do print("  " .. t .. "  " .. addr) end
  return
end
print("Found housing component: " .. tostring(ctype))

local function dump(name, value)
  local f = io.open(name, "w")
  f:write(ser.serialize(value))
  f:close()
  print("  wrote " .. name)
end

local muts = housing.getBeeBreedingData()
dump("bee_mutations.dat", muts)
print("  (" .. #muts .. " mutations)")

dump("bee_species.dat", housing.listAllSpecies())

-- Genome template -- only if an analyzed queen is currently in the apiary.
local ok, queen = pcall(function() return housing.getQueen() end)
if ok and queen then
  dump("queen_genome.dat", queen)
else
  print("  (no analyzed queen in apiary; skipped queen_genome.dat)")
end

print("Done. Copy the .dat files into the bee_serious repo and commit.")
