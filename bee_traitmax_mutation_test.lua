--[[
  Unit tests for bee_traitmax_mutation.lua -- the pure donor-selection core.
  Synthetic templates + a simple isGood predicate; no hardware.
--]]

local TM = require("bee_traitmax_mutation")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- Targets: fertility >= 4, speed >= 3, lifespan <= 2 (lower is better here).
local function isGood(trait, value)
  if trait == "fertility" then return value >= 4 end
  if trait == "speed" then return value >= 3 end
  if trait == "lifespan" then return value <= 2 end
  return true
end
local TRAITS = { "fertility", "speed", "lifespan" }

-- Templates: no single species is good at everything.
local templates = {
  Common     = { fertility = 4, speed = 1, lifespan = 5 },  -- fertility only
  Cultivated = { fertility = 2, speed = 3, lifespan = 5 },  -- speed only
  Wintry     = { fertility = 1, speed = 1, lifespan = 1 },  -- lifespan only
  Meadows    = { fertility = 4, speed = 3, lifespan = 5 },  -- fertility + speed
  Barren     = { fertility = 1, speed = 1, lifespan = 9 },  -- nothing good
}

-- ============================================================
-- donorsForTrait
-- ============================================================

do
  local d = TM.donorsForTrait(templates, "fertility", isGood)
  check("donorsForTrait fertility = species with fertility>=4", d.Common and d.Meadows and not d.Cultivated)
  local s = TM.donorsForTrait(templates, "speed", isGood)
  check("donorsForTrait speed = species with speed>=3", s.Cultivated and s.Meadows and not s.Common)
  local l = TM.donorsForTrait(templates, "lifespan", isGood)
  check("donorsForTrait lifespan = species with lifespan<=2 (only Wintry)", l.Wintry and not l.Common)
end

-- ============================================================
-- selectDonors: minimal set cover
-- ============================================================

do
  local r = TM.selectDonors(templates, TRAITS, isGood, {})
  -- Meadows covers fertility+speed, Wintry covers lifespan -> 2 donors, all traits covered.
  check("selectDonors covers every trait", r.perTrait.fertility and r.perTrait.speed and r.perTrait.lifespan)
  check("selectDonors picks the MINIMAL set (Meadows + Wintry)",
    #r.donors == 2 and has(r.donors, "Meadows") and has(r.donors, "Wintry"),
    table.concat(r.donors, ","))
  check("selectDonors: Meadows covers fertility AND speed", r.perTrait.fertility == "Meadows" and r.perTrait.speed == "Meadows")
  check("selectDonors: Wintry covers lifespan", r.perTrait.lifespan == "Wintry")
  check("selectDonors: no uncoverable traits here", #r.uncoverable == 0)
end

-- ============================================================
-- needed = donors we don't own yet (what to MUTATE for)
-- ============================================================

do
  local r = TM.selectDonors(templates, TRAITS, isGood, { Wintry = true })
  check("needed excludes owned donors (Wintry owned -> only Meadows needed)",
    #r.needed == 1 and r.needed[1] == "Meadows", table.concat(r.needed, ","))
end

do
  -- Owning a species with unique coverage makes it preferred over acquiring a new
  -- one: own Common (fertility) + Cultivated (speed) -> those are free, so the
  -- greedy prefers them and only needs Wintry for lifespan.
  local r = TM.selectDonors(templates, TRAITS, isGood, { Common = true, Cultivated = true })
  check("prefers owned donors, only needs the uncovered one (Wintry)",
    #r.needed == 1 and r.needed[1] == "Wintry", table.concat(r.needed, ","))
end

-- ============================================================
-- uncoverable: a trait no known species is good at
-- ============================================================

do
  local traits = { "fertility", "speed", "lifespan", "flowering" } -- flowering absent from all templates
  local r = TM.selectDonors(templates, traits, isGood, {})
  check("uncoverable lists a trait no species supplies (flowering)",
    #r.uncoverable == 1 and r.uncoverable[1] == "flowering", table.concat(r.uncoverable, ","))
  check("uncoverable trait has no perTrait entry", r.perTrait.flowering == nil)
end

-- ============================================================
-- determinism
-- ============================================================

do
  local r1 = TM.selectDonors(templates, TRAITS, isGood, {})
  local r2 = TM.selectDonors(templates, TRAITS, isGood, {})
  check("selectDonors is deterministic",
    table.concat(r1.donors, ",") == table.concat(r2.donors, ","))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
