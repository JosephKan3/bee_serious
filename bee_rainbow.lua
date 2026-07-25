--[[
  Bee Rainbow
  ------------
  Pure module for RAINBOW mode: obtain a purebred bank of EVERY attainable
  species, on top of the genebank machinery. It answers two questions and nothing
  else (no hardware, no scheduling):

    M.targetSet(graph, ownedLeaves)                       -> which species to get
    M.nextTarget(graph, ownedLeaves, banked, targetSet)   -> which one to build next

  The target-set is a decoupled PROVIDER so the scope can change without touching
  the manager. The MVP provider (M.reachableTargets, used by M.targetSet) is
  "every producible species reachable from the base leaves you actually hold".
  A user-supplied list or an all-producible provider can replace it later by
  passing a different `targetSet` into M.nextTarget -- the manager only depends on
  these two calls.

  ORDER: build SHALLOW species before DEEP ones. With already-banked species
  treated as available parents, the shallowest unbanked target is only one
  mutation away from current stock, so each rainbow step adds one layer and every
  target's parents are already on hand when its turn comes -- the same bottom-up
  discipline the genebank scheduler uses within a single tree.
--]]

local MG = require("bee_mutation_graph")

local M = {}

-- MVP provider: every PRODUCIBLE species reachable using ONLY the base leaves you
-- actually hold. computeCosts treats every unheld leaf as acquirable, so a bare
-- cost check would include species that still need a leaf you don't have -- we
-- filter those out by requiring the plan's missingLeaves to be empty. One shared
-- fixpoint (computeCosts) + a cheap per-species buildPlan.
function M.reachableTargets(graph, ownedLeaves)
  local owned = ownedLeaves or {}
  local costs = MG.computeCosts(graph, owned)
  local set = {}
  for sp in pairs(graph.producible or {}) do
    if costs.cost[sp] ~= nil then
      local plan = MG.buildPlan(owned, sp, costs)
      if #plan.missingLeaves == 0 then set[sp] = true end
    end
  end
  return set
end

-- The set of species rainbow should obtain. Defaults to reachableTargets; pass a
-- different provider (e.g. a user list) as `provider(graph, ownedLeaves)`.
function M.targetSet(graph, ownedLeaves, provider)
  provider = provider or M.reachableTargets
  return provider(graph, ownedLeaves)
end

-- The next species to build a purebred bank of: an unbanked member of targetSet
-- that is reachable NOW (treating banked species + base leaves as available
-- parents), preferring the shallowest (lowest breeding cost). Deterministic on
-- ties (lexicographic). Returns nil when every target is banked -> rainbow done.
function M.nextTarget(graph, ownedLeaves, banked, targetSet)
  local owned = {}
  for sp in pairs(ownedLeaves or {}) do owned[sp] = true end
  for sp in pairs(banked or {}) do owned[sp] = true end

  local costs = MG.computeCosts(graph, owned)
  local best, bestCost
  for sp in pairs(targetSet or {}) do
    if not (banked or {})[sp] then
      local c = costs.cost[sp]
      if c ~= nil then
        if not best or c < bestCost or (c == bestCost and sp < best) then
          best, bestCost = sp, c
        end
      end
    end
  end
  return best
end

-- How many targets are still unbanked (for progress reporting).
function M.remaining(banked, targetSet)
  local n = 0
  for sp in pairs(targetSet or {}) do
    if not (banked or {})[sp] then n = n + 1 end
  end
  return n
end

return M
