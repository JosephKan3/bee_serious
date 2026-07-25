--[[
  Bee Templates loader
  --------------------
  Turns the parsed bee_templates.dat (Java-enum-keyed, normalized-name values --
  see scripts/parse_bee_templates.lua) into the species->template map that
  bee_traitmax_mutation.selectDonors consumes: keyed by LIVE display name, with
  RAW genome values (via bee_allele_values).

  Two mismatches are reconciled here:
    1. Values: normalized enum names -> raw genome values (bee_allele_values).
    2. Names: template keys are Java enum constants (CULTIVATED, BIGBAD,
       AM_EARTH); the live mutation graph uses display names (Cultivated,
       "Big Bad", ...). M.canonical() strips mod prefixes + non-alphanumerics
       and uppercases both sides so they line up. Forestry (base-game) templates
       win over modded ones on a canonical collision.

  M.build is restricted to a caller-supplied set of live species (the ones a
  traitmax project can actually reach), so unreconcilable modded templates never
  matter unless they're in play.
--]]

local values = require("bee_allele_values")

local M = {}

-- Mod branch/species prefixes on the Java enum constants. Stripped so
-- "AM_EARTH" can line up with a live "Earth" display name.
local PREFIXES = { "AM_", "BOT_", "AE_", "EB_", "MB_", "GT_", "GENDUSTRY_" }

-- Fold a species name (either side) to a comparable key.
function M.canonical(name)
  local s = tostring(name):upper()
  for _, p in ipairs(PREFIXES) do
    if s:sub(1, #p) == p then s = s:sub(#p + 1); break end
  end
  return (s:gsub("[^A-Z0-9]", ""))
end

-- Load the parsed table. bee_templates.dat is a `return {...}` Lua chunk.
function M.load(path)
  path = path or "bee_templates.dat"
  local chunk = loadfile(path)
  if not chunk then return nil end
  return chunk()
end

local SOURCE_RANK = { forestry = 3, extrabees = 2, magicbees = 1 }

local function asList(liveSpecies)
  if not liveSpecies then return {} end
  if liveSpecies[1] ~= nil then return liveSpecies end -- already an array
  local list = {}                                       -- given as a set
  for name in pairs(liveSpecies) do list[#list + 1] = name end
  return list
end

-- Build { [liveDisplayName] = { [trait] = rawValue } } for the live species that
-- have a matching template. liveSpecies is an array or set of display names.
function M.build(parsed, liveSpecies)
  local liveByCanon = {}
  for _, name in ipairs(asList(liveSpecies)) do
    liveByCanon[M.canonical(name)] = name
  end

  -- Best template per canonical name (forestry > extrabees > magicbees).
  local bestByCanon = {}
  for key, entry in pairs(parsed or {}) do
    if entry.traits and next(entry.traits) then
      local canon = M.canonical(key)
      local rank = SOURCE_RANK[entry.source] or 0
      local cur = bestByCanon[canon]
      if not cur or rank > cur.rank then
        bestByCanon[canon] = { entry = entry, rank = rank }
      end
    end
  end

  local out = {}
  for canon, disp in pairs(liveByCanon) do
    local best = bestByCanon[canon]
    if best then out[disp] = values.templateToRaw(best.entry.traits) end
  end
  return out
end

return M
