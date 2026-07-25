--[[
  Bee Allele Value Mapping
  ------------------------
  bee_templates.dat stores allele values as NORMALIZED ENUM NAMES ("fast",
  "high", "shortest", "both5", "true") -- see scripts/parse_bee_templates.lua.
  But bee_trait_config.isGoodValue compares against the RAW genome values the
  live Forestry API returns (speed floats like 1.2, fertility ints like 4,
  lifespan ints like 10, tolerance strings like "BOTH_5", booleans).

  This pure module bridges the two: M.toRaw(trait, normValue) -> raw value, so
  a parsed template can feed bee_traitmax_mutation.selectDonors with
  bee_trait_config.isGoodValue as the predicate.

  The numeric scales are the EXACT EnumAllele values from the Forestry source
  (forestry/core/genetics/alleles/EnumAllele.java). Both the Forestry enum name
  ("normal") and the MagicBees base-allele short form ("norm") are aliased where
  they differ. Tolerance/flowerProvider raw forms are the best-known live shapes
  (bee_trait_config's targets); confirm against a live getQueen dump if a trait
  ever mis-judges (see docs/data_sources.md TODO #1).
--]]

local M = {}

-- Exact EnumAllele numeric scales (Forestry EnumAllele.java).
M.speed = {
  slowest = 0.3, slower = 0.6, slow = 0.8, normal = 1.0, norm = 1.0,
  fast = 1.2, faster = 1.4, fastest = 1.7,
}
M.fertility = { low = 1, normal = 2, norm = 2, high = 3, maximum = 4 }
M.flowering = {
  slowest = 5, slower = 10, slow = 15, average = 20, fast = 25,
  faster = 30, fastest = 35, maximum = 99,
}
M.lifespan = {
  shortest = 10, shorter = 20, short = 30, shortened = 35, normal = 40,
  norm = 40, elongated = 45, long = 50, longer = 60, longest = 70,
}

local NUMERIC = {
  speed = M.speed, fertility = M.fertility,
  flowering = M.flowering, lifespan = M.lifespan,
}
local BOOL = { nocturnal = true, tolerantFlyer = true, caveDwelling = true }

-- "both5" -> "BOTH_5", "up1" -> "UP_1", "none" -> "NONE". bee_trait_config
-- compares tolerance with the underscore form.
local function toleranceRaw(v)
  if v == "none" then return "NONE" end
  local word, num = v:match("^(%a+)(%d+)$")
  if word then return word:upper() .. "_" .. num end
  return v:upper()
end

-- "wheat" -> "flowersWheat" (live genome's camelCase flowerProvider form).
local function flowerRaw(v)
  return "flowers" .. v:sub(1, 1):upper() .. v:sub(2)
end

-- Convert one normalized template value for `trait` to its raw genome value.
-- Unknown traits (effect/territory/species) pass through unchanged -- they are
-- "any" in bee_trait_config, so the raw form doesn't matter to isGoodValue.
function M.toRaw(trait, v)
  if v == nil then return nil end
  local numeric = NUMERIC[trait]
  if numeric then return numeric[v] end
  if BOOL[trait] then return (v == "true" or v == true) end
  if trait == "temperatureTolerance" or trait == "humidityTolerance" then
    return toleranceRaw(v)
  end
  if trait == "flowerProvider" then return flowerRaw(v) end
  return v
end

-- Convert a whole template's { [trait] = normValue } to { [trait] = rawValue }.
function M.templateToRaw(traits)
  local out = {}
  for t, v in pairs(traits or {}) do out[t] = M.toRaw(t, v) end
  return out
end

return M
