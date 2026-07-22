--[[
  Bee Mutation Graph
  -------------------
  Pure module (no component/hardware access) over the real GTNH bee mutation
  graph dumped from a stationary OC Adapter's tile_for_apiculture_0_name
  component (getBeeBreedingData) -- see docs/oc_forestry_api.md. Kept pure and
  data-in/data-out for the same reason bee_breeding.lua is: the planning logic
  is fully testable off-hardware (see bee_mutation_graph_test.lua) and the
  simulator can drive it at full speed.

  DATA SHAPE (one entry per mutation, from getBeeBreedingData):
    { allele1="Forest", allele2="Meadows", chance=15.0, result="Common",
      specialConditions={ "Occurs within a plains biome.", ... } }
  allele1/allele2/result are plain species DISPLAY NAMES (strings). allele1 =
  getAllele0(), allele2 = getAllele1(). Princess/drone DIRECTION matters for
  triggering a mutation (not for normal inheritance), and the mapping is
  CONFIRMED: allele1 = princess, allele2 = drone.

  PATH SELECTION (user's call): when multiple breeding paths reach a target,
  prefer the LEAST special-condition burden -- weight each step by how hard its
  conditions are (dimension >> foundation block > biome > climate > time >
  none), then fewest steps, then highest chance. In GTNH a dimension trip or a
  rare foundation block is far more work than an extra breeding step, so this
  minimizes real effort. Unavoidable conditions still surface to the user via
  the beep-and-await gate at execution time.
--]]

local M = {}

-- ============================================================
-- Special-condition classification + cost
-- ============================================================
--
-- Categories are matched against the human-readable strings Forestry's
-- getSpecialConditions() returns (confirmed against the real dump -- see
-- docs/oc_forestry_api.md for the full observed set). Costs are ORDINAL: their
-- only job is to rank paths in the requested priority order. Condition cost
-- dominates step count (a shallow tree is never worth a dimension trip), and
-- step count dominates the chance tiebreaker.
M.CONDITION_COST = {
  dimension = 10000,   -- "Required Dimension Moon" -- whole setup must be in that dim
  foundation = 1000,   -- "Requires Block of Zinc as a foundation." -- place a block
  biome = 500,         -- "Occurs within a nether biome." / "Required Biome ..."
  climate = 300,       -- "Requires Icy temperature." / "... humidity." / "between ..."
  time = 100,          -- "During the night." / "During the New Moon" / date windows
  unknown = 300,       -- anything unrecognized -- treat as moderately hard
}

M.STEP_COST = 1            -- per breeding step (secondary to conditions)
M.LEAF_ACQUIRE_COST = 1    -- acquiring a base (unproducible) species the user lacks

-- Classify one condition string into a category key (see M.CONDITION_COST).
function M.classifyCondition(str)
  local s = tostring(str):lower()
  if s:find("dimension") then return "dimension" end
  if s:find("foundation") then return "foundation" end
  if s:find("biome") then return "biome" end
  if s:find("temperature") or s:find("humidity") then return "climate" end
  if s:find("during") or s:find("between") or s:find("night") or s:find("moon") then return "time" end
  return "unknown"
end

-- Total ordinal cost of a recipe's special conditions (0 if unconditional).
function M.conditionCost(conditions)
  if not conditions then return 0 end
  local total = 0
  for _, c in ipairs(conditions) do
    total = total + (M.CONDITION_COST[M.classifyCondition(c)] or M.CONDITION_COST.unknown)
  end
  return total
end

-- ============================================================
-- Graph parsing / normalization
-- ============================================================

-- Turns the raw getBeeBreedingData array into an indexed graph:
--   byResult[result] = { { princess, drone, chance, conditions, condCost }, ... }
--   allSpecies       = set of every species name (any role)
--   producible       = set of species that are some mutation's result
--   leaves           = set of species that appear ONLY as parents (base stock)
function M.build(rawMutations)
  local byResult, allSpecies, producible, asParent = {}, {}, {}, {}
  for _, m in ipairs(rawMutations) do
    local princess, drone, result = m.allele1, m.allele2, m.result
    if princess and drone and result then
      allSpecies[princess] = true
      allSpecies[drone] = true
      allSpecies[result] = true
      asParent[princess] = true
      asParent[drone] = true
      producible[result] = true
      byResult[result] = byResult[result] or {}
      table.insert(byResult[result], {
        princess = princess,
        drone = drone,
        chance = m.chance or 0,
        conditions = m.specialConditions or {},
        condCost = M.conditionCost(m.specialConditions),
      })
    end
  end
  local leaves = {}
  for name in pairs(asParent) do
    if not producible[name] then leaves[name] = true end
  end
  return { byResult = byResult, allSpecies = allSpecies, producible = producible, leaves = leaves }
end

-- Convenience: parse a serialization.serialize() string (valid Lua) into a
-- graph. Kept separate from M.build so the planner stays free of any string/IO
-- concern and tests can pass a plain table. `loader` defaults to Lua's load.
function M.parse(serialized, loader)
  loader = loader or load
  local chunk = loader("return " .. serialized)
  return M.build(chunk())
end

-- ============================================================
-- Tree planner
-- ============================================================
--
-- A mutation needs BOTH parents, so this is a min-cost AND-OR graph
-- (hypergraph) problem, not a simple shortest path -- and mutation graphs
-- contain cycles (e.g. A+B->C and C+D->A). Naive memoized DFS is order-
-- dependent and gives wrong (too-high, spuriously "unreachable") costs on
-- cyclic AND-OR graphs, so costs are computed by Bellman-Ford-style fixpoint
-- RELAXATION instead: cost of every species is relaxed against every recipe
-- repeatedly until nothing improves. Every step adds STEP_COST (> 0), so the
-- chosen-recipe pointers can't form a cycle (a result always costs strictly
-- more than either parent), which makes the tree reconstruction acyclic.
--
-- Priority (user's call): condition burden dominates (a recipe's condCost is
-- 100s-10000s), then step count (STEP_COST=1 each), then higher chance (a tiny
-- negative tiebreak, << STEP_COST, so it only separates otherwise-equal paths).

local CHANCE_TIEBREAK = 0.001

-- Relaxes cost[] for ALL species at once from the owned set. Returns
-- { cost = { [species]=number }, recipe = { [species]=chosenRecipe|nil } }.
-- cost[s] absent = unreachable. recipe[s] nil = owned or an acquirable leaf.
-- Missing (unproducible, unowned) species get a fixed LEAF_ACQUIRE_COST so a
-- tree that needs them is still planned; the reconstruction reports which ones
-- a given target actually uses.
function M.computeCosts(graph, owned)
  owned = owned or {}
  local cost, recipe = {}, {}

  for s in pairs(owned) do cost[s] = 0 end
  -- Every unproducible species in the graph is a parent-only leaf (never a
  -- result). Unowned ones are acquirable base stock at a fixed small cost.
  for s in pairs(graph.leaves) do
    if not owned[s] then cost[s] = M.LEAF_ACQUIRE_COST end
  end

  local changed = true
  while changed do
    changed = false
    for result, recipes in pairs(graph.byResult) do
      if not owned[result] then
        for _, r in ipairs(recipes) do
          local cp, cd = cost[r.princess], cost[r.drone]
          if cp and cd then
            local cand = M.STEP_COST + r.condCost + cp + cd - (r.chance or 0) * CHANCE_TIEBREAK
            if cost[result] == nil or cand < cost[result] then
              cost[result] = cand
              recipe[result] = r
              changed = true
            end
          end
        end
      end
    end
  end

  return { cost = cost, recipe = recipe }
end

-- Walks the chosen-recipe tree (costs.recipe, from computeCosts) rooted at
-- `target` in TOPOLOGICAL order: visit(species, recipe) fires for each species
-- that must be BRED (has a chosen recipe) only AFTER both its parents have been
-- walked. Shared intermediates are visited exactly once; cycle-safe. Traversal
-- stops at owned species (a boundary). onLeaf(species), if given, fires once
-- per acquirable base leaf the tree depends on (reachable, not owned, no chosen
-- recipe).
--
-- Deliberately DECOUPLED from any plan/cost/plan-shape concern -- it's the one
-- canonical tree walk reused by plan building (below), by execution (breed each
-- visited step in order), by condition scanning, and by display. Pure.
function M.traverseTree(recipe, owned, target, visit, onLeaf)
  owned = owned or {}
  local seen = {}
  local function walk(species)
    if owned[species] or seen[species] then return end
    seen[species] = true
    local r = recipe[species]
    if not r then
      if onLeaf then onLeaf(species) end
      return
    end
    walk(r.princess)
    walk(r.drone)
    visit(species, r)
  end
  walk(target)
end

-- Plans a breeding tree for one target from a precomputed cost table (from
-- M.computeCosts). Kept separate so a caller checking many targets against the
-- same owned set computes the fixpoint ONCE (see the real-data test / any
-- future "which of these can I make" query). Just accumulates M.traverseTree.
--
-- Returns:
--   { reachable=bool, alreadyOwned=bool,
--     steps = { { result, princess, drone, chance, conditions }, ... },
--             -- topologically ordered: every step's parents are owned, a
--             -- missing leaf, or produced by an EARLIER step.
--     missingLeaves = { name, ... },  -- base species THIS tree needs that
--             -- aren't owned -- what the user must go gather.
--     totalCost = number|nil }
function M.buildPlan(owned, target, costs)
  owned = owned or {}
  if owned[target] then
    return { reachable = true, alreadyOwned = true, steps = {}, missingLeaves = {}, totalCost = 0 }
  end
  if costs.cost[target] == nil then
    return { reachable = false, alreadyOwned = false, steps = {}, missingLeaves = {}, totalCost = nil }
  end

  local steps, missing = {}, {}
  M.traverseTree(costs.recipe, owned, target,
    function(species, r)
      table.insert(steps, {
        result = species, princess = r.princess, drone = r.drone,
        chance = r.chance, conditions = r.conditions,
      })
    end,
    function(leaf) missing[leaf] = true end)

  return {
    reachable = true, alreadyOwned = false, steps = steps,
    missingLeaves = M._setToSortedList(missing), totalCost = costs.cost[target],
  }
end

-- Convenience: full plan for one target (computes the cost fixpoint then
-- reconstructs). Planning is rare (one target request), so the per-call
-- fixpoint is fine; use computeCosts + buildPlan directly to reuse one
-- fixpoint across many targets.
function M.planBreedingTree(graph, owned, target)
  return M.buildPlan(owned, target, M.computeCosts(graph, owned))
end

-- Deterministic sorted list from a set (stable output for logs/tests).
function M._setToSortedList(set)
  local list = {}
  for k in pairs(set) do table.insert(list, k) end
  table.sort(list)
  return list
end

return M
