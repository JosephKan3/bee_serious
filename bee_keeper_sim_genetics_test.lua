--[[
  Tests for bee_keeper_sim.lua's genetics: species dominance expression and that
  purebred x purebred stays purebred. Uses the exported M.crossRaw / M.makeGoodRaw
  directly (no world install needed).
--]]

local Sim = require("bee_keeper_sim")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local function pureParent(name)
  local sp = { name = name, uid = "sim." .. name:lower() }
  return { species = { active = sp, inactive = sp } }
end

-- ============================================================
-- Dominance rank is deterministic
-- ============================================================

do
  check("speciesDominanceRank is deterministic",
    Sim.speciesDominanceRank("Forest") == Sim.speciesDominanceRank("Forest"))
  check("distinct species get (generally) distinct ranks",
    Sim.speciesDominanceRank("Forest") ~= Sim.speciesDominanceRank("Wintry"))
end

-- ============================================================
-- Purebred x purebred (same species) stays purebred
-- ============================================================

do
  math.randomseed(12345)
  local allPure = true
  for _ = 1, 50 do
    local c = Sim.crossRaw({ "species" }, pureParent("Forest"), pureParent("Forest"))
    if not (c.species.active.name == "Forest" and c.species.inactive.name == "Forest") then
      allPure = false
    end
  end
  check("pure Forest x pure Forest -> pure Forest, every time", allPure)
end

-- ============================================================
-- Hybrid expresses the DOMINANT species as active, recessive as inactive
-- ============================================================

do
  local dom = (Sim.speciesDominanceRank("Wintry") > Sim.speciesDominanceRank("Forest"))
    and "Wintry" or "Forest"
  local rec = (dom == "Wintry") and "Forest" or "Wintry"

  math.randomseed(999)
  local ok = true
  for _ = 1, 50 do
    -- Try both parent orderings -- dominance, not parent role, decides active.
    local c1 = Sim.crossRaw({ "species" }, pureParent("Forest"), pureParent("Wintry"))
    local c2 = Sim.crossRaw({ "species" }, pureParent("Wintry"), pureParent("Forest"))
    for _, c in ipairs({ c1, c2 }) do
      -- genotype is always the hybrid {Forest, Wintry}
      local names = { [c.species.active.name] = true, [c.species.inactive.name] = true }
      if not (names.Forest and names.Wintry) then ok = false end
      -- active is the dominant one, inactive the recessive one
      if c.species.active.name ~= dom or c.species.inactive.name ~= rec then ok = false end
    end
  end
  check("hybrid Forest/Wintry always expresses the dominant species as active", ok,
    "dominant expected = " .. dom)
end

-- ============================================================
-- makeGoodRaw / makeStartingRaw produce purebred species (both alleles equal)
-- ============================================================

do
  local Cfg = require("bee_trait_config")
  local traits = Cfg.activeTraits(); table.insert(traits, "species")
  local g = Sim.makeGoodRaw(traits, "Common")
  check("makeGoodRaw seeds a purebred species (active==inactive)",
    g.species.active.name == "Common" and g.species.inactive.name == "Common")
end

-- ============================================================
-- applyMutation: a mutation yields a HYBRID (real Forestry) -- the result
-- species' template lands on the ACTIVE side (how its good alleles ENTER the
-- pool), while the INACTIVE side keeps the Mendelian allele inherited from a
-- parent. So the offspring is Result/parent, never purebred Result; a pure
-- Result is only reached later by breeding two carriers together (the
-- scheduler's `fix` job). Modelling it as instantly-pure hid a real dead-end.
-- ============================================================

do
  local traitList = { "species", "fertility", "lifespan", "nocturnal" }
  -- A hybrid parent-blend child whose traits are all "bad" (base-ish) values.
  local child = {
    species = { active = { name = "Forest" }, inactive = { name = "Meadows" } },
    fertility = { active = 2, inactive = 1 },
    lifespan = { active = 40, inactive = 60 },
    nocturnal = { active = false, inactive = false },
  }
  -- Template map: the result species "Ended" is a donor for fertility+nocturnal.
  local templates = { Ended = { fertility = 4, nocturnal = true } }
  Sim.applyMutation(child, "Ended", templates, traitList)

  check("applyMutation makes a HYBRID: Result active, inherited parent allele inactive",
    child.species.active.name == "Ended" and child.species.inactive.name == "Meadows",
    "got " .. tostring(child.species.active.name) .. "/" .. tostring(child.species.inactive.name))
  check("applyMutation puts the template's good fertility on the ACTIVE side, keeps inherited inactive",
    child.fertility.active == 4 and child.fertility.inactive == 1,
    "got " .. tostring(child.fertility.active) .. "/" .. tostring(child.fertility.inactive))
  check("applyMutation puts the template's good nocturnal active, keeps inherited inactive",
    child.nocturnal.active == true and child.nocturnal.inactive == false)
  check("non-override trait: active from base default (lifespan 20), inactive inherited (60)",
    child.lifespan.active == 20 and child.lifespan.inactive == 60,
    "got " .. tostring(child.lifespan.active) .. "/" .. tostring(child.lifespan.inactive))
end

do
  -- Without templates, applyMutation only changes the species locus (active side),
  -- leaving the child a hybrid with the inherited inactive allele intact.
  local child = { species = { active = { name = "A" }, inactive = { name = "B" } },
                  fertility = { active = 1, inactive = 1 } }
  Sim.applyMutation(child, "Common", nil, { "species", "fertility" })
  check("applyMutation without templates: Result active, inherited species inactive, traits untouched",
    child.species.active.name == "Common" and child.species.inactive.name == "B"
      and child.fertility.active == 1)
end

-- ============================================================
-- M.mate: the faithful Forestry mating used by the sim's apiaries.
--  * mutation lookup is SYMMETRIC (princess/drone species order irrelevant)
--  * a successful mutation replaces a whole parent slot with the pure result
--    template, so the offspring carries the result species on >=1 allele
--  * pure x pure of the SAME species always stays pure
-- ============================================================

-- A symmetric pair index like bee_keeper_sim builds internally: both orders.
local function symIndex(a, b, result, chance)
  local idx = {}
  for _, key in ipairs({ a .. "|" .. b, b .. "|" .. a }) do
    idx[key] = { { result = result, chance = chance, conditions = {} } }
  end
  return idx
end

do
  -- Forest x Meadows -> Common at 100% (guaranteed), tried BOTH parent orders.
  local idx = symIndex("Forest", "Meadows", "Common", 100)
  local templates = {} -- no trait overrides; species-only tracking
  math.randomseed(2024)
  local forestFirst, meadowsFirst = 0, 0
  for _ = 1, 200 do
    local c1 = Sim.mate({ "species" }, pureParent("Forest"), pureParent("Meadows"), idx, templates, 1)
    local c2 = Sim.mate({ "species" }, pureParent("Meadows"), pureParent("Forest"), idx, templates, 1)
    if c1.species.active.name == "Common" or c1.species.inactive.name == "Common" then forestFirst = forestFirst + 1 end
    if c2.species.active.name == "Common" or c2.species.inactive.name == "Common" then meadowsFirst = meadowsFirst + 1 end
  end
  check("mate: Forest princess x Meadows drone yields Common carriers", forestFirst > 0, "got " .. forestFirst)
  check("mate: Meadows princess x Forest drone ALSO yields Common (symmetric)", meadowsFirst > 0, "got " .. meadowsFirst)
end

do
  -- Pure x pure of the SAME species: no recipe for (X,X), so always pure X.
  local idx = symIndex("Forest", "Meadows", "Common", 100)
  math.randomseed(77)
  local allPure = true
  for _ = 1, 100 do
    local c = Sim.mate({ "species" }, pureParent("Common"), pureParent("Common"), idx, {}, 1)
    if not (c.species.active.name == "Common" and c.species.inactive.name == "Common") then allPure = false end
  end
  check("mate: pure Common x pure Common stays pure Common", allPure)
end

do
  -- Zero-chance recipe never fires -> offspring is a plain Mendelian hybrid,
  -- never the result species.
  local idx = symIndex("Forest", "Meadows", "Common", 0)
  math.randomseed(5)
  local sawCommon = false
  for _ = 1, 100 do
    local c = Sim.mate({ "species" }, pureParent("Forest"), pureParent("Meadows"), idx, {}, 1)
    if c.species.active.name == "Common" or c.species.inactive.name == "Common" then sawCommon = true end
  end
  check("mate: 0%-chance recipe never produces the result species", not sawCommon)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
