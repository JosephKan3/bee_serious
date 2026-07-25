--[[
  Unit tests for bee_traitmax.lua -- the two-phase traitmax orchestrator that
  composes reachability (bee_rainbow) + donor selection (bee_traitmax_mutation).
--]]

local MG = require("bee_mutation_graph")
local TM = require("bee_traitmax")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end
local function set(...) local s = {}; for _, v in ipairs({ ... }) do s[v] = true end; return s end

-- Synthetic tree: Forest x Wintry -> Fast; Forest x Meadows -> Fertile;
--                 Fast x Fertile -> Deep.  Leaves: Forest, Wintry, Meadows.
local graph = MG.build({
  { allele1 = "Forest", allele2 = "Wintry", result = "Fast", chance = 15 },
  { allele1 = "Forest", allele2 = "Meadows", result = "Fertile", chance = 15 },
  { allele1 = "Fast", allele2 = "Fertile", result = "Deep", chance = 10 },
})
local LEAVES = set("Forest", "Wintry", "Meadows")

-- Templates: Fast is a speed donor, Fertile a fertility donor, Deep neither.
-- (Java-enum-keyed, normalized-name values -- as bee_templates.load() returns.)
local parsed = {
  FAST    = { kind = "species", source = "forestry", traits = { speed = "fastest" } },
  FERTILE = { kind = "species", source = "forestry", traits = { fertility = "maximum" } },
  DEEP    = { kind = "species", source = "forestry", traits = {} },
  FOREST  = { kind = "species", source = "forestry", traits = {} },
}
-- Simple isGood: speed>=1.7 (fastest), fertility>=4 (maximum).
local function isGood(trait, v)
  if trait == "speed" then return type(v) == "number" and v >= 1.7 end
  if trait == "fertility" then return type(v) == "number" and v >= 4 end
  return false
end
local traitList = { "speed", "fertility" }

-- ============================================================
-- plan: picks the donor species that cover the target traits
-- ============================================================

do
  local p = TM.plan(graph, LEAVES, parsed, traitList, isGood)
  check("plan selects Fast (speed donor)", p.donorSet.Fast, table.concat(p.donors, ","))
  check("plan selects Fertile (fertility donor)", p.donorSet.Fertile)
  check("plan does NOT select Deep (covers nothing)", not p.donorSet.Deep)
  check("perTrait maps speed->Fast", p.perTrait.speed == "Fast")
  check("perTrait maps fertility->Fertile", p.perTrait.fertility == "Fertile")
  check("no uncoverable traits (both have reachable donors)", #p.uncoverable == 0)
end

-- ============================================================
-- uncoverable: a target trait no reachable species is good at
-- ============================================================

do
  local p = TM.plan(graph, LEAVES, parsed, { "speed", "fertility", "lifespan" }, isGood)
  check("lifespan is uncoverable (no donor)", p.uncoverable[1] == "lifespan")
end

-- ============================================================
-- phase: acquire until all donors banked, then combine
-- ============================================================

do
  local p = TM.plan(graph, LEAVES, parsed, traitList, isGood)
  check("phase = acquire when nothing banked", TM.phase(p.donorSet, {}) == "acquire")
  check("phase = acquire when only one donor banked",
    TM.phase(p.donorSet, set("Fast")) == "acquire")
  check("phase = combine when all donors banked",
    TM.phase(p.donorSet, set("Fast", "Fertile")) == "combine")
end

-- ============================================================
-- nextDonor: shallowest-first over the donor set (both 1 step from leaves)
-- ============================================================

do
  local p = TM.plan(graph, LEAVES, parsed, traitList, isGood)
  local n = TM.nextDonor(graph, LEAVES, {}, p.donorSet)
  check("nextDonor returns a donor to bank first", n == "Fast" or n == "Fertile", tostring(n))
  check("remaining = 2 donors when none banked", TM.remaining(p.donorSet, {}) == 2)
  check("remaining = 0 when both banked", TM.remaining(p.donorSet, set("Fast", "Fertile")) == 0)
  check("nextDonor = nil when all banked",
    TM.nextDonor(graph, LEAVES, set("Fast", "Fertile"), p.donorSet) == nil)
end

-- ============================================================
-- End-to-end over the REAL data (graph + templates + trait_config)
-- ============================================================

do
  local realGraph
  local f = io.open("bee_mutations.dat", "r")
  if f then local s = f:read("*a"); f:close(); realGraph = MG.parse(s) end
  local parsedReal = require("bee_templates").load("bee_templates.dat")
  if realGraph and parsedReal then
    local Cfg = require("bee_trait_config")
    -- A plausible starter leaf set (the user's starter list).
    local leaves = set("Forest", "Meadows", "Modest", "Tropical", "Wintry",
                       "Marshy", "Rocky", "Ocean")
    local p = TM.plan(realGraph, leaves, parsedReal, Cfg.activeTraits(), Cfg.isGoodValue)
    check("real plan returns a donor set", type(p.donorSet) == "table")
    print(string.format("  (real traitmax plan: %d donors, %d need acquiring, %d uncoverable)",
      #p.donors, #p.needed, #p.uncoverable))
  else
    print("  (skipped real-data check: bee_mutations.dat / bee_templates.dat not loadable)")
  end
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
