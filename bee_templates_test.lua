-- Tests for bee_allele_values + bee_templates (value + name reconciliation).
package.path = package.path .. ";./?.lua"
local values = require("bee_allele_values")
local templates = require("bee_templates")
local traitConfig = require("bee_trait_config")
local traitmax = require("bee_traitmax_mutation")

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. msg) end
end
local function eq(a, b, msg) ok(a == b, (msg or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

print("== bee_allele_values ==")
eq(values.toRaw("speed", "fast"), 1.2, "speed fast")
eq(values.toRaw("speed", "fastest"), 1.7, "speed fastest")
eq(values.toRaw("speed", "norm"), 1.0, "speed norm alias")
eq(values.toRaw("fertility", "maximum"), 4, "fertility maximum")
eq(values.toRaw("fertility", "high"), 3, "fertility high")
eq(values.toRaw("lifespan", "shortest"), 10, "lifespan shortest")
eq(values.toRaw("lifespan", "longest"), 70, "lifespan longest")
eq(values.toRaw("flowering", "fastest"), 35, "flowering fastest")
eq(values.toRaw("flowering", "maximum"), 99, "flowering maximum")
eq(values.toRaw("nocturnal", "true"), true, "nocturnal true")
eq(values.toRaw("caveDwelling", "false"), false, "caveDwelling false")
eq(values.toRaw("temperatureTolerance", "both5"), "BOTH_5", "tolerance both5")
eq(values.toRaw("humidityTolerance", "up1"), "UP_1", "tolerance up1")
eq(values.toRaw("temperatureTolerance", "none"), "NONE", "tolerance none")
eq(values.toRaw("flowerProvider", "wheat"), "flowersWheat", "flowerProvider wheat")
eq(values.toRaw("effect", "ectoplasm"), "ectoplasm", "unknown trait passthrough")

-- Values feed bee_trait_config.isGoodValue correctly.
print("== raw values judged by bee_trait_config ==")
ok(traitConfig.isGoodValue("fertility", values.toRaw("fertility", "maximum")), "maximum fertility is good")
ok(not traitConfig.isGoodValue("fertility", values.toRaw("fertility", "low")), "low fertility is bad")
ok(traitConfig.isGoodValue("lifespan", values.toRaw("lifespan", "shortest")), "shortest lifespan is good")
ok(not traitConfig.isGoodValue("lifespan", values.toRaw("lifespan", "longest")), "longest lifespan is bad")
ok(traitConfig.isGoodValue("flowering", values.toRaw("flowering", "fastest")), "fastest flowering is good")

print("== bee_templates.canonical ==")
eq(templates.canonical("CULTIVATED"), "CULTIVATED", "enum key")
eq(templates.canonical("Cultivated"), "CULTIVATED", "display name matches enum")
eq(templates.canonical("BIGBAD"), "BIGBAD", "no-space enum")
eq(templates.canonical("Big Bad"), "BIGBAD", "display with space matches")
eq(templates.canonical("AM_EARTH"), "EARTH", "prefix stripped")
eq(templates.canonical("Arcane Shard"), "ARCANESHARD", "two-word display")

print("== bee_templates.build (synthetic) ==")
local parsed = {
  CULTIVATED = { kind = "species", source = "forestry", traits = { speed = "fast", lifespan = "shortest" } },
  ARCANE = { kind = "species", source = "forestry", traits = { fertility = "high" } },
  AM_ARCANE = { kind = "template", source = "magicbees", traits = { fertility = "low" } },
}
local built = templates.build(parsed, { "Cultivated", "Arcane", "Meadows" })
eq(built.Cultivated and built.Cultivated.speed, 1.2, "Cultivated speed raw")
eq(built.Cultivated and built.Cultivated.lifespan, 10, "Cultivated lifespan raw")
eq(built.Arcane and built.Arcane.fertility, 3, "forestry wins collision (high=3, not low)")
ok(built.Meadows == nil, "unmatched live species has no template")

print("== bee_templates.build (real bee_templates.dat) ==")
local real = templates.load("bee_templates.dat")
ok(real ~= nil, "loaded bee_templates.dat")
if real then
  -- Core Forestry line reconciles by display name.
  local live = { "Common", "Cultivated", "Noble", "Diligent", "Unweary",
                 "Industrious", "Meadows", "Forest" }
  local map = templates.build(real, live)
  local matched = 0
  for _ in pairs(map) do matched = matched + 1 end
  ok(matched >= 4, "at least 4 core species reconciled (got " .. matched .. ")")
  -- Cultivated is fast + shortest lifespan in Forestry -> good speed/lifespan.
  if map.Cultivated then
    ok(map.Cultivated.lifespan ~= nil, "Cultivated has a lifespan template value")
  end

  -- End-to-end: donor selection over the real template map for the traits
  -- bee_trait_config actually targets.
  local activeTraits = traitConfig.activeTraits()
  local result = traitmax.selectDonors(map, activeTraits, traitConfig.isGoodValue, {})
  ok(type(result.donors) == "table", "selectDonors returns donors over real data")
  print(string.format("  (real donor selection: %d donors, %d uncoverable of %d active traits)",
    #result.donors, #result.uncoverable, #activeTraits))
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
