--[[
  Tests for bee_mutation_graph.lua -- pure, no hardware. Synthetic hand-built
  graphs for deterministic assertions (condition costs, path selection,
  topological ordering, cycle safety, missing leaves), plus a real-data smoke
  test against the committed bee_mutations.dat.
--]]

local MG = require("bee_mutation_graph")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

local function set(...)
  local s = {}
  for _, v in ipairs({ ... }) do s[v] = true end
  return s
end

-- Validates a step list is topologically ordered: walking it in order, every
-- step's princess/drone is already available (owned, a missing leaf, or the
-- result of an earlier step) before it's used. Returns true + final available
-- set, or false + the offending step.
local function validateTopo(steps, owned, missingLeaves)
  local available = {}
  for k in pairs(owned) do available[k] = true end
  for _, m in ipairs(missingLeaves or {}) do available[m] = true end
  for i, s in ipairs(steps) do
    if not available[s.princess] then return false, i, s.princess end
    if not available[s.drone] then return false, i, s.drone end
    available[s.result] = true
  end
  return true, available
end

-- ============================================================
-- classifyCondition / conditionCost
-- ============================================================
do
  check("classify dimension", MG.classifyCondition("Required Dimension Moon") == "dimension")
  check("classify foundation", MG.classifyCondition("Requires Block of Zinc as a foundation.") == "foundation")
  check("classify biome", MG.classifyCondition("Occurs within a nether biome.") == "biome")
  check("classify climate temp", MG.classifyCondition("Requires Icy temperature.") == "climate")
  check("classify climate humidity", MG.classifyCondition("Requires Arid humidity.") == "climate")
  check("classify time night", MG.classifyCondition("During the night.") == "time")
  check("classify unknown", MG.classifyCondition("Some bizarre requirement") == "unknown")

  check("unconditional cost is 0", MG.conditionCost({}) == 0)
  check("dimension costs more than foundation",
    MG.conditionCost({ "Required Dimension Moon" }) > MG.conditionCost({ "Requires X as a foundation." }))
  check("foundation costs more than time",
    MG.conditionCost({ "Requires X as a foundation." }) > MG.conditionCost({ "During the night." }))
  check("two conditions sum", MG.conditionCost({ "During the night.", "During the New Moon" })
    == 2 * MG.CONDITION_COST.time)
end

-- ============================================================
-- build: indexing + leaf detection
-- ============================================================
do
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 10, result = "C", specialConditions = {} },
    { allele1 = "C", allele2 = "D", chance = 5, result = "E", specialConditions = {} },
  })
  check("build indexes by result", g.byResult["C"] ~= nil and g.byResult["E"] ~= nil)
  check("build records princess/drone direction",
    g.byResult["C"][1].princess == "A" and g.byResult["C"][1].drone == "B")
  check("leaves are parent-only species", g.leaves["A"] and g.leaves["B"] and g.leaves["D"])
  check("produced species are not leaves", not g.leaves["C"] and not g.leaves["E"])
end

-- ============================================================
-- planBreedingTree: basics
-- ============================================================
do
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 10, result = "C", specialConditions = {} },
  })

  local ownedTarget = MG.planBreedingTree(g, set("C"), "C")
  check("already-owned target returns empty plan",
    ownedTarget.alreadyOwned and #ownedTarget.steps == 0 and ownedTarget.reachable)

  local plan = MG.planBreedingTree(g, set("A", "B"), "C")
  check("single-step plan reachable with 1 step", plan.reachable and #plan.steps == 1)
  check("single-step plan assigns princess/drone",
    plan.steps[1].result == "C" and plan.steps[1].princess == "A" and plan.steps[1].drone == "B")
  check("single-step plan has no missing leaves", #plan.missingLeaves == 0)

  local missing = MG.planBreedingTree(g, set("A"), "C")  -- lacks B
  check("missing base leaf is reported", missing.missingLeaves[1] == "B", table.concat(missing.missingLeaves, ","))
end

-- ============================================================
-- planBreedingTree: multi-step topological ordering
-- ============================================================
do
  -- E needs C+D; C needs A+B. Owned = A,B,D. Must breed C before E.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 10, result = "C", specialConditions = {} },
    { allele1 = "C", allele2 = "D", chance = 10, result = "E", specialConditions = {} },
  })
  local owned = set("A", "B", "D")
  local plan = MG.planBreedingTree(g, owned, "E")
  check("multi-step reachable", plan.reachable and #plan.steps == 2)
  local ok, info = validateTopo(plan.steps, owned, plan.missingLeaves)
  check("multi-step is topologically ordered (parents before children)", ok,
    ok and "" or ("bad step " .. tostring(info)))
  check("final step produces the target", plan.steps[#plan.steps].result == "E")
end

-- ============================================================
-- traverseTree: decoupled topological walk (shared by plan/execution/display)
-- ============================================================
do
  -- E needs C+D; C needs A+B; D needs C+X. Owned A,B,X. C is shared by E and D
  -- and must be visited once, before both.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 10, result = "C", specialConditions = {} },
    { allele1 = "C", allele2 = "X", chance = 10, result = "D", specialConditions = {} },
    { allele1 = "C", allele2 = "D", chance = 10, result = "E", specialConditions = {} },
  })
  local owned = set("A", "B", "X")
  local costs = MG.computeCosts(g, owned)

  local order, visitCount, leaves = {}, {}, {}
  MG.traverseTree(costs.recipe, owned, "E",
    function(sp) table.insert(order, sp); visitCount[sp] = (visitCount[sp] or 0) + 1 end,
    function(leaf) leaves[leaf] = true end)

  check("traverseTree visits each bred species exactly once",
    visitCount.C == 1 and visitCount.D == 1 and visitCount.E == 1)
  -- position checks: C before D, C before E, D before E
  local pos = {}; for i, s in ipairs(order) do pos[s] = i end
  check("traverseTree is topological (shared intermediate first)",
    pos.C < pos.D and pos.C < pos.E and pos.D < pos.E, table.concat(order, ","))
  check("traverseTree does not visit owned species (boundary)",
    visitCount.A == nil and visitCount.B == nil and visitCount.X == nil)
  check("traverseTree reports no missing leaves when all leaves owned", next(leaves) == nil)

  -- Drop X from owned -> it becomes an acquirable missing leaf reported via onLeaf.
  local owned2 = set("A", "B")
  local costs2 = MG.computeCosts(g, owned2)
  local leaves2 = {}
  MG.traverseTree(costs2.recipe, owned2, "E", function() end, function(l) leaves2[l] = true end)
  check("traverseTree onLeaf reports an unowned base leaf", leaves2.X == true)
end

-- ============================================================
-- Path selection: least special-condition burden dominates
-- ============================================================
do
  -- Two ways to make T, both from owned A+B: one unconditional, one needing a
  -- foundation. Planner must pick the unconditional one.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 20, result = "T",
      specialConditions = { "Requires Block of Zinc as a foundation." } },
    { allele1 = "A", allele2 = "B", chance = 20, result = "T", specialConditions = {} },
  })
  local plan = MG.planBreedingTree(g, set("A", "B"), "T")
  check("prefers the unconditional recipe over a conditioned one",
    #plan.steps == 1 and #plan.steps[1].conditions == 0)
end

do
  -- Dimension (harder) vs foundation (easier), both single-step: pick foundation.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 20, result = "T",
      specialConditions = { "Required Dimension Moon" } },
    { allele1 = "A", allele2 = "B", chance = 20, result = "T",
      specialConditions = { "Requires Block of Zinc as a foundation." } },
  })
  local plan = MG.planBreedingTree(g, set("A", "B"), "T")
  check("prefers foundation over dimension when both needed",
    MG.classifyCondition(plan.steps[1].conditions[1]) == "foundation")
end

do
  -- Among equal (zero) conditions, fewest steps wins: a direct unconditional
  -- recipe beats a longer unconditional path.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 10, result = "X", specialConditions = {} },
    { allele1 = "X", allele2 = "A", chance = 10, result = "T", specialConditions = {} }, -- 2 steps
    { allele1 = "A", allele2 = "B", chance = 10, result = "T", specialConditions = {} }, -- 1 step direct
  })
  local plan = MG.planBreedingTree(g, set("A", "B"), "T")
  check("fewest steps wins among equally-conditioned paths", #plan.steps == 1)
end

do
  -- Equal cost and equal steps: higher chance breaks the tie.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 5, result = "T", specialConditions = {} },
    { allele1 = "A", allele2 = "B", chance = 40, result = "T", specialConditions = {} },
  })
  local plan = MG.planBreedingTree(g, set("A", "B"), "T")
  check("higher chance breaks an exact tie", plan.steps[1].chance == 40,
    "chose chance=" .. tostring(plan.steps[1].chance))
end

-- ============================================================
-- Cycle safety
-- ============================================================
do
  -- A+B->C, C+D->A : cyclic. Owning A,B,D, target C must still resolve (via
  -- the direct A+B->C) without infinite recursion.
  local g = MG.build({
    { allele1 = "A", allele2 = "B", chance = 10, result = "C", specialConditions = {} },
    { allele1 = "C", allele2 = "D", chance = 10, result = "A", specialConditions = {} },
  })
  local plan = MG.planBreedingTree(g, set("A", "B", "D"), "C")
  check("cyclic graph resolves without hanging", plan.reachable and #plan.steps == 1)
end

-- ============================================================
-- Real data smoke test (committed bee_mutations.dat)
-- ============================================================
do
  local f = io.open("bee_mutations.dat", "r")
  if not f then
    print("SKIP real-data test (bee_mutations.dat not in cwd)")
  else
    local serialized = f:read("*a"); f:close()
    local graph = MG.parse(serialized)

    local mutCount = 0
    for _, recipes in pairs(graph.byResult) do mutCount = mutCount + #recipes end
    check("real graph has 538 mutations", mutCount == 538, "got " .. mutCount)

    local leafCount = 0
    for _ in pairs(graph.leaves) do leafCount = leafCount + 1 end
    check("real graph has 18 leaf species", leafCount == 18, "got " .. leafCount)

    -- Own every leaf, compute the cost fixpoint ONCE, then reconstruct every
    -- target from it (fast). Every real-data plan must be topologically valid
    -- and (since all leaves are owned) never report a missing leaf.
    local ownAllLeaves = {}
    for name in pairs(graph.leaves) do ownAllLeaves[name] = true end
    local costs = MG.computeCosts(graph, ownAllLeaves)

    local checkedTargets, unreachable, allTopo, allNoMissing = 0, 0, true, true
    for result in pairs(graph.producible) do
      local plan = MG.buildPlan(ownAllLeaves, result, costs)
      checkedTargets = checkedTargets + 1
      if not plan.reachable then unreachable = unreachable + 1 end
      if #plan.missingLeaves > 0 then allNoMissing = false end
      if not validateTopo(plan.steps, ownAllLeaves, plan.missingLeaves) then allTopo = false end
    end
    check("every real-data plan is topologically valid (" .. checkedTargets .. " targets)", allTopo)
    check("no missing leaves when all leaves owned", allNoMissing)
    -- A handful of species may be genuinely unreachable by pure breeding even
    -- from all leaves (acquire-only bees that only appear as a mutation result
    -- via a self-referential/cyclic recipe). That's real data, not a planner
    -- bug -- but the OVERWHELMING majority must be reachable. Report the count.
    check("vast majority of producible species reachable from all leaves ("
      .. (checkedTargets - unreachable) .. "/" .. checkedTargets .. ")",
      unreachable <= checkedTargets * 0.05, unreachable .. " unreachable")

    -- Determinism: same inputs -> identical plan (planner has no randomness).
    local someTarget = next(graph.producible)
    local p1 = MG.planBreedingTree(graph, ownAllLeaves, someTarget)
    local p2 = MG.planBreedingTree(graph, ownAllLeaves, someTarget)
    check("planner is deterministic", #p1.steps == #p2.steps)
  end
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
