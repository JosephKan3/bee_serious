--[[
  Bee Genebank Scheduler
  -----------------------
  Pure module (no hardware/graph access) that decides the NEXT breeding JOB for a
  genebank-managed mutation program. It replaces the old greedy "re-derive the
  deepest step every visit" logic, which never dedicated apiary time to growing an
  intermediate's DRONE bank up to reserve -- so deep (3+ step) trees stalled.

  THE STRATEGY (from docs/gtnh_bee_genetics.md + the v0.3 design memo):
    * Every species in the tree gets a purebred BANK: >= minPrincesses pure
      princesses + >= minDrones pure drones, built PURE x PURE (never drifts).
    * Build banks BOTTOM-UP and to FULL target size before spending them: an
      intermediate's drone bank is grown to reserve BEFORE it's used as a parent
      for the next level. This is the fix for deep trees.
    * A pristine princess is never lost (breeding transforms her genotype, always
      yielding a replacement princess), so the princess pool is conserved: when a
      parent's princess is spent into a mutation, its line is renewed by CONVERTING
      a pristine hybrid byproduct back to it (genotype-judged) -- never exhausted.
    * The final TARGET only needs to be REACHED (one pure princess), not a full
      bank -- from there the site hands off to species mode.

  This module is data-in/data-out over a snapshot; the manager scans hardware into
  `state`, calls M.nextJob, and executes the returned job. Fully testable off
  hardware (see bee_genebank_scheduler_test.lua).

  JOB TYPES returned by M.nextJob(state):
    { type="mutate", princess=A, drone=B, result=X }  -- breed A(princess) x B(drone) for X
    { type="grow",   species=X }                       -- breed X x X to grow X's drone bank
    { type="convert",to=Y }                            -- recycle a hybrid byproduct into Y
    { type="done" }                                    -- target reached
    { type="blocked", need=<string> }                  -- can't proceed (e.g. need pristine base)
--]]

local M = {}

-- Bank target for a species: the final target only needs to be REACHED (1
-- princess, no drone bank); every other species needs the full reserve.
local function bankTarget(species, target, minP, minD)
  if species == target then return 1, 0 end
  return minP, minD
end

local function bankOf(banks, s)
  return banks[s] or { purePrincesses = 0, pureDrones = 0 }
end

local function sortedKeys(set)
  local list = {}
  for k in pairs(set) do list[#list + 1] = k end
  table.sort(list)
  return list
end

-- state = {
--   banks       = { [species] = { purePrincesses=, pureDrones= } },  -- current pure stock
--   convertible = { [species] = <# pristine hybrid princesses carrying a `species` allele> },
--   steps       = { { result=, princess=, drone= }, ... },  -- topological (parents before
--                   children), e.g. from bee_mutation_graph.planBreedingTree(graph,
--                   baseSpecies, target).steps
--   baseSpecies = { [species]=true },   -- species with an external pristine supply (leaves)
--   target      = <species>,
--   minPrincesses, minDrones,
-- }
function M.nextJob(state)
  local banks = state.banks or {}
  local convertible = state.convertible or {}
  local steps = state.steps or {}
  local base = state.baseSpecies or {}
  local target = state.target
  local minP = state.minPrincesses or 1
  local minD = state.minDrones or 8

  -- Reached the goal: one pure princess of the target is enough.
  if bankOf(banks, target).purePrincesses >= 1 then return { type = "done" } end

  -- Which base species the tree actually uses (as a parent of some step).
  local usedBase = {}
  for _, step in ipairs(steps) do
    if base[step.princess] then usedBase[step.princess] = true end
    if base[step.drone] then usedBase[step.drone] = true end
  end

  -- Phase 1 -- base banks first (deterministic order). A base species short of
  -- princesses is renewed by converting a byproduct (its pool is conserved); short
  -- of drones, grown pure x pure. If it can't be renewed at all, we're blocked.
  for _, b in ipairs(sortedKeys(usedBase)) do
    local have = bankOf(banks, b)
    local tp, td = bankTarget(b, target, minP, minD)
    if have.purePrincesses < tp then
      if (convertible[b] or 0) >= 1 and have.pureDrones >= 1 then
        return { type = "convert", to = b }
      end
      return { type = "blocked", need = "pristine princess of '" .. b .. "'" }
    end
    if have.pureDrones < td then
      return { type = "grow", species = b }
    end
  end

  -- Phase 2 -- intermediates then target, in topological order. The first species
  -- whose bank isn't at target decides the job; because parents come earlier in
  -- the order, a short parent is handled before the child that needs it.
  for _, step in ipairs(steps) do
    local X, A, B = step.result, step.princess, step.drone
    local have = bankOf(banks, X)
    local tp, td = bankTarget(X, target, minP, minD)
    local aHasPrincess = bankOf(banks, A).purePrincesses >= 1
    local bHasDrone = bankOf(banks, B).pureDrones >= 1

    if have.purePrincesses < tp then
      -- Need (more) X princesses -> mutate, if the parents can supply a
      -- princess of A and a drone of B right now.
      if aHasPrincess and bHasDrone then
        return { type = "mutate", princess = A, drone = B, result = X }
      end
      -- Parent A is short a princess (likely just spent) -> renew A by converting
      -- a byproduct back to it, so the mutation can run next.
      if not aHasPrincess and (convertible[A] or 0) >= 1 and bankOf(banks, A).pureDrones >= 1 then
        return { type = "convert", to = A }
      end
      -- Otherwise a parent isn't ready yet; an earlier step/base handles it. If
      -- nothing earlier claimed a job we fall through to "blocked" below.
    elseif X ~= target and have.pureDrones < td then
      -- Grow X's drone bank BEFORE it's spent as a parent upstream.
      if have.pureDrones >= 1 then
        return { type = "grow", species = X }
      end
      -- Have an X princess but no X drone yet -> mutate more X to seed drones.
      if aHasPrincess and bHasDrone then
        return { type = "mutate", princess = A, drone = B, result = X }
      end
    end
    -- X's bank is at target -> continue up the tree.
  end

  -- Every bank looks satisfied yet the target isn't reached -- shouldn't happen
  -- with a well-formed plan; report so the caller re-plans rather than spins.
  return { type = "blocked", need = "no actionable job (replan)" }
end

M._bankTarget = bankTarget
return M
