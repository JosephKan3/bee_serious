--[[
  Parse per-species DEFAULT allele templates out of the mod source (Forestry,
  ExtraBees/Binnie, MagicBees) into bee_templates.dat -- the data traitmax-via-
  mutation needs (which species carries a good allele for each trait). See
  docs/data_sources.md for the repo paths and the three source formats.

  Run:  lua scripts/parse_bee_templates.lua  (edit SOURCES below to your paths)

  Output: bee_templates.dat, a serialized Lua table
    { [speciesOrBranchName] = { kind="species"|"branch"|"template",
                                source="forestry"|"extrabees"|"magicbees",
                                traits = { [trait] = "<enum/allele value>" } }, ... }

  NOTE: values are the RAW enum/allele names from source (e.g. Speed.FAST ->
  "FAST", getBaseAllele("speedFast") -> "speedFast", booleans -> "true"). Mapping
  those to the numeric genome values bee_trait_config uses is a documented TODO
  (see docs/data_sources.md) -- confirm exact numbers against a live getQueen dump.
--]]

local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
local SOURCES = {
  forestry  = "C:/Users/Joseph Kan/Desktop/ForestryMC/src/main/java/forestry/apiculture/genetics/BeeDefinition.java",
  extrabees = "C:/Users/Joseph Kan/Desktop/Binnie/src/main/java/binnie/extrabees/genetics/ExtraBeeBranchDefinition.java",
  magicbees = "C:/Users/Joseph Kan/Desktop/MagicBees/src/main/java/magicbees/bees/BeeGenomeManager.java",
}

-- EnumBeeChromosome -> our trait key.
local CHROM = {
  SPEED = "speed", FERTILITY = "fertility", LIFESPAN = "lifespan",
  FLOWERING = "flowering", TEMPERATURE_TOLERANCE = "temperatureTolerance",
  HUMIDITY_TOLERANCE = "humidityTolerance", NOCTURNAL = "nocturnal",
  TOLERANT_FLYER = "tolerantFlyer", CAVE_DWELLING = "caveDwelling",
  TERRITORY = "territory", EFFECT = "effect", FLOWER_PROVIDER = "flowerProvider",
}

-- Normalize an allele value to a common form across sources: Forestry uses enum
-- value names (Speed.FAST -> "FAST", "BOTH_2"); MagicBees uses getBaseAllele keys
-- ("speedFast", "toleranceBoth1", "boolTrue"). Strip the MagicBees category
-- prefix, drop underscores, lowercase -> "fast", "both2", "true", "elongated".
local VAL_PREFIXES = { "temperature", "humidity", "tolerance", "fertility",
  "lifespan", "flowering", "territory", "flowers", "effect", "speed", "bool" }
local function normVal(raw)
  for _, p in ipairs(VAL_PREFIXES) do
    if #raw > #p and raw:sub(1, #p):lower() == p and raw:sub(#p + 1, #p + 1):match("%u") then
      raw = raw:sub(#p + 1)
      break
    end
  end
  return (raw:gsub("_", ""):lower())
end

local out = {}
local function rec(name, kind, source)
  out[name] = out[name] or { kind = kind, source = source, traits = {} }
  return out[name]
end

local function readLines(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local lines = {}
  for l in f:lines() do lines[#lines + 1] = l end
  f:close()
  return lines
end

-- Forestry / ExtraBees share the AlleleHelper.instance.set(...) form. They differ
-- only in how the enclosing NAME is declared (enum constant), so a namePattern is
-- passed in. kind = "species" (forestry) or "branch" (extrabees).
local function parseAlleleHelper(lines, source, namePattern, kind)
  local current
  for _, l in ipairs(lines) do
    local nm = l:match(namePattern)
    if nm then current = rec(nm, kind, source) end
    if current then
      local chrom, val = l:match("EnumBeeChromosome%.([A-Z_]+),%s*EnumAllele%.[A-Za-z]+%.([A-Za-z0-9_]+)")
      if not chrom then
        chrom, val = l:match("EnumBeeChromosome%.([A-Z_]+),%s*(true)")
        if not chrom then chrom, val = l:match("EnumBeeChromosome%.([A-Z_]+),%s*(false)") end
      end
      if chrom and CHROM[chrom] then current.traits[CHROM[chrom]] = normVal(val) end
    end
  end
end

-- MagicBees: getTemplateX() { genome = getTemplateModBase(); genome[SPECIES]=BeeSpecies.NAME;
--   genome[CHROM.ordinal()] = Allele.getBaseAllele("value"); ... }. Keyed by the BeeSpecies name.
local function parseMagicBees(lines, source)
  local current
  for _, l in ipairs(lines) do
    if l:match("getTemplate[A-Za-z0-9_]+%(%)") then current = nil end -- new method; species set on its own line
    local sp = l:match("EnumBeeChromosome%.SPECIES%.ordinal%(%)%]%s*=%s*BeeSpecies%.([A-Z0-9_]+)")
    if sp then current = rec(sp, "template", source) end
    local chrom, val = l:match("EnumBeeChromosome%.([A-Z_]+)%.ordinal%(%)%]%s*=%s*Allele%.getBaseAllele%(\"([A-Za-z0-9_]+)\"")
    local base = (current == nil) and rec("_MODBASE", "template", source) or current
    if chrom and CHROM[chrom] then base.traits[CHROM[chrom]] = normVal(val) end
  end
end

local fl = readLines(SOURCES.forestry)
if fl then parseAlleleHelper(fl, "forestry", "^%s+([A-Z][A-Z0-9_]+)%(BeeBranchDefinition", "species") end
local eb = readLines(SOURCES.extrabees)
if eb then parseAlleleHelper(eb, "extrabees", "^    ([A-Z][A-Z0-9_]+)%(\"", "branch") end
local mb = readLines(SOURCES.magicbees)
if mb then parseMagicBees(mb, "magicbees") end

-- serialize (sorted, deterministic)
local names = {}
for k in pairs(out) do names[#names + 1] = k end
table.sort(names)
local buf = { "return {" }
for _, name in ipairs(names) do
  local e = out[name]
  local traits = {}
  local tk = {}
  for t in pairs(e.traits) do tk[#tk + 1] = t end
  table.sort(tk)
  for _, t in ipairs(tk) do traits[#traits + 1] = string.format("%s=%q", t, e.traits[t]) end
  buf[#buf + 1] = string.format("  [%q]={kind=%q,source=%q,traits={%s}},",
    name, e.kind, e.source, table.concat(traits, ", "))
end
buf[#buf + 1] = "}"
local of = io.open("bee_templates.dat", "w")
of:write(table.concat(buf, "\n"))
of:close()

local n, withTraits = 0, 0
for _, e in pairs(out) do n = n + 1; if next(e.traits) then withTraits = withTraits + 1 end end
print(string.format("wrote bee_templates.dat: %d entries (%d with allele overrides)", n, withTraits))
