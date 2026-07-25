--[[
  Unit tests for bee_rainbow.lua -- the pure rainbow target-set / next-target
  provider. Uses a synthetic mutation graph via bee_mutation_graph.build.
--]]

local MG = require("bee_mutation_graph")
local R = require("bee_rainbow")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Synthetic tree:
--   Forest x Wintry -> Common
--   Common x Forest -> Cultivated
--   Common x Cultivated -> Noble
--   Forest x Meadows -> Sib        (a second branch off the base leaves)
-- Leaves (parent-only): Forest, Wintry, Meadows.
local graph = MG.build({
  { allele1 = "Forest", allele2 = "Wintry", result = "Common", chance = 15 },
  { allele1 = "Common", allele2 = "Forest", result = "Cultivated", chance = 12 },
  { allele1 = "Common", allele2 = "Cultivated", result = "Noble", chance = 10 },
  { allele1 = "Forest", allele2 = "Meadows", result = "Sib", chance = 15 },
})
local function set(...) local s = {}; for _, v in ipairs({ ... }) do s[v] = true end; return s end
local LEAVES = set("Forest", "Wintry", "Meadows")

-- ============================================================
-- targetSet = all producible reachable from the leaves
-- ============================================================

do
  local ts = R.targetSet(graph, LEAVES)
  check("targetSet includes all producible reachable species",
    ts.Common and ts.Cultivated and ts.Noble and ts.Sib)
  check("targetSet excludes base leaves (they're not producible)",
    not ts.Forest and not ts.Wintry and not ts.Meadows)
end

do
  -- With only Forest+Wintry (no Meadows), Sib is unreachable -> excluded.
  local ts = R.targetSet(graph, set("Forest", "Wintry"))
  check("targetSet excludes species unreachable from held leaves (no Meadows -> no Sib)",
    ts.Common and ts.Noble and not ts.Sib)
end

-- ============================================================
-- nextTarget: shallowest unbanked, bottom-up
-- ============================================================

do
  local ts = R.targetSet(graph, LEAVES)
  -- Nothing banked: shallowest producible are Common (Forest x Wintry) and Sib
  -- (Forest x Meadows), both 1 step. Deterministic tie -> lexicographic "Common".
  local n1 = R.nextTarget(graph, LEAVES, {}, ts)
  check("nextTarget picks a 1-step species first (Common, by tie-break)", n1 == "Common", n1)

  -- With Common banked, both Cultivated (1 step from Common) and Sib (1 step from
  -- leaves) are shallowest; either is a valid next (order among equal-depth
  -- targets is decided by cost/chance and doesn't matter for coverage).
  local n2 = R.nextTarget(graph, LEAVES, set("Common"), ts)
  check("nextTarget advances to a 1-step species once Common is banked",
    n2 == "Cultivated" or n2 == "Sib", n2)

  -- With Common+Cultivated+Sib banked, only Noble remains.
  local n3 = R.nextTarget(graph, LEAVES, set("Common", "Cultivated", "Sib"), ts)
  check("nextTarget picks the last remaining target (Noble)", n3 == "Noble", n3)

  -- Everything banked -> nil (rainbow complete).
  local n4 = R.nextTarget(graph, LEAVES, set("Common", "Cultivated", "Noble", "Sib"), ts)
  check("nextTarget returns nil when all targets banked", n4 == nil)
end

do
  -- Deep target isn't chosen before its parents: Noble must not come before Common.
  local ts = R.targetSet(graph, LEAVES)
  local n = R.nextTarget(graph, LEAVES, {}, ts)
  check("nextTarget never picks a deep species before its parents", n ~= "Noble", n)
end

-- ============================================================
-- remaining
-- ============================================================

do
  local ts = R.targetSet(graph, LEAVES)
  check("remaining counts unbanked targets", R.remaining(set("Common"), ts) == 3,
    tostring(R.remaining(set("Common"), ts)))
  check("remaining is 0 when all banked",
    R.remaining(set("Common", "Cultivated", "Noble", "Sib"), ts) == 0)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
