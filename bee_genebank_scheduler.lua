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
    { type="fix",    species=X }                       -- carrier princess x carrier drone -> pure X
    { type="seedDrone",   species=X, drone=B }         -- carrier princess x pure parent -> carrier DRONES
    { type="seedPrincess",species=X, princess=A }      -- pure parent x carrier drone -> carrier PRINCESSES
    { type="done" }                                    -- target reached
    { type="blocked", need=<string> }                  -- can't proceed (e.g. need pristine base)
--]]

local M = {}

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
  local convertible = state.convertible or {}       -- hybrid PRINCESSES carrying an allele
  local convertibleDrones = state.convertibleDrones or {} -- hybrid DRONES carrying an allele
  local steps = state.steps or {}
  local base = state.baseSpecies or {}
  local target = state.target
  local minP = state.minPrincesses or 1
  local minD = state.minDrones or 8

  -- Reached the goal: one pure princess of the target is enough.
  if bankOf(banks, target).purePrincesses >= 1 then return { type = "done" } end

  -- Which role each species is SPENT in up-tree (a princess parent of some step, a
  -- drone parent of some step, or both). A species is built ONE surplus unit above
  -- reserve in each role it is spent in, so the spend draws only that surplus and the
  -- reserve is never breached.
  local princessParent, droneParent = {}, {}
  for _, step in ipairs(steps) do
    princessParent[step.princess] = true
    droneParent[step.drone] = true
  end

  -- BUILD TARGET (how full to stock a species). The TARGET only needs to be REACHED
  -- (1 pure princess, no drone bank -- it is the endpoint, never spent onward). Every
  -- other species keeps its full reserve (minP princesses + minD drones) PLUS one
  -- surplus unit in each role it is spent in.
  local function buildTarget(sp)
    if sp == target then return 1, 0 end
    return minP + (princessParent[sp] and 1 or 0), minD + (droneParent[sp] and 1 or 0)
  end

  -- SPEND FLOOR: the inviolable reserve. A pure princess / drone of sp may be spent as
  -- a FOREIGN parent (or, for the princess, destructively via growDrone) only from
  -- SURPLUS strictly above minP / minD -- never down into the reserve.
  local function princessSurplus(sp) return bankOf(banks, sp).purePrincesses > minP end
  local function droneSurplus(sp) return bankOf(banks, sp).pureDrones > minD end

  local function nV(sp) return (convertible[sp] or 0) >= 1 end        -- carrier PRINCESS of sp
  local function nW(sp) return (convertibleDrones[sp] or 0) >= 1 end  -- carrier DRONE of sp

  -- One job that raises X's pure PRINCESS count. Consolidate X's OWN carriers first
  -- (fix / convert -- no foreign spend); introduce a missing carrier role from a
  -- FOREIGN parent's SURPLUS (seed); create the first carriers by mutating A x B from
  -- surplus. nil if nothing on hand can advance it (a parent still needs building).
  local function buildPrincessJob(X, A, B)
    local h = bankOf(banks, X)
    local haveV, haveW = nV(X), nW(X)
    if h.purePrincesses < 1 and haveV and haveW then return { type = "fix", species = X } end
    if haveV and h.pureDrones >= 1 then return { type = "convert", to = X } end
    if haveW and not haveV and princessSurplus(A) then return { type = "seedPrincess", species = X, princess = A } end
    if haveV and not haveW and droneSurplus(B) then return { type = "seedDrone", species = X, drone = B } end
    if not haveV and not haveW and princessSurplus(A) and droneSurplus(B) then
      return { type = "mutate", princess = A, drone = B, result = X }
    end
    return nil
  end

  -- One job that raises X's pure DRONE count. grow the pair; else bootstrap from
  -- carriers (fix); else -- only from a SURPLUS princess -- growDrone; else seed the
  -- missing carrier role from a foreign surplus parent so fix can run; else mutate.
  local function buildDroneJob(X, A, B)
    local h = bankOf(banks, X)
    local haveV, haveW = nV(X), nW(X)
    if h.purePrincesses >= 1 and h.pureDrones >= 1 then return { type = "grow", species = X } end
    if haveV and haveW then return { type = "fix", species = X } end
    if haveW and princessSurplus(X) then return { type = "growDrone", species = X } end
    if haveV and not haveW and droneSurplus(B) then return { type = "seedDrone", species = X, drone = B } end
    if haveW and not haveV and princessSurplus(A) then return { type = "seedPrincess", species = X, princess = A } end
    if not haveV and not haveW and princessSurplus(A) and droneSurplus(B) then
      return { type = "mutate", princess = A, drone = B, result = X }
    end
    return nil
  end

  -- Which base species the tree actually uses (as a parent of some step).
  local usedBase = {}
  for _, step in ipairs(steps) do
    if base[step.princess] then usedBase[step.princess] = true end
    if base[step.drone] then usedBase[step.drone] = true end
  end

  -- Phase 1 -- base banks (deterministic order). The hard PRINCESS reserve comes
  -- first (losing it loses the base): renew from a byproduct carrier, else block for a
  -- pristine restock. Then grow the drone bank toward its build target. A base's
  -- princess SURPLUS is only buildable by converting a byproduct carrier against a
  -- surplus drone; if no carrier exists yet it's left for later (byproducts supply it
  -- as the tree runs, or the user restocks) rather than blocking.
  for _, b in ipairs(sortedKeys(usedBase)) do
    local have = bankOf(banks, b)
    local bp, bd = buildTarget(b)
    if have.purePrincesses < minP then
      if nV(b) and have.pureDrones >= 1 then return { type = "convert", to = b } end
      return { type = "blocked", need = "pristine princess of '" .. b .. "'" }
    end
    if have.pureDrones < bd and have.pureDrones >= 1 then
      return { type = "grow", species = b }
    end
    if have.purePrincesses < bp and nV(b) and droneSurplus(b) then
      return { type = "convert", to = b }
    end
  end

  -- Phase 2 -- intermediates then target, in topological order. Parents come earlier,
  -- so a parent that lacks the SURPLUS to be spent is built up before the child that
  -- needs it. Reserves are never drawn down: every cross-species spend (mutate / seed)
  -- takes only a parent's SURPLUS, while a species' OWN bank is built with fix /
  -- convert / grow (and, only from a surplus princess, growDrone). A mutation yields
  -- HYBRIDS (carriers of X), never a pure X; the first pure X comes from fix (carrier
  -- V:X x carrier W:X ~25% pure), so carriers are consolidated before re-mutating.
  for _, step in ipairs(steps) do
    local X, A, B = step.result, step.princess, step.drone
    local have = bankOf(banks, X)
    local rp = (X == target) and 1 or minP           -- hard princess RESERVE
    local sp, sd = buildTarget(X)                     -- reserve + surplus (spent role)

    -- Tiers, in order: (1) reach the hard PRINCESS reserve; (2) build DRONES to
    -- reserve+surplus -- drones come before princess surplus because surplus drones are
    -- what a princess surplus is purified against; (3) build the PRINCESS surplus X owes
    -- as a princess parent. A cross-species spend inside these only ever takes a
    -- FOREIGN parent's surplus (never its reserve); if a parent lacks surplus, fall
    -- through -- an earlier step (or base Phase 1) builds it first, in topological order.
    local job
    if have.purePrincesses < rp then
      job = buildPrincessJob(X, A, B)
    elseif X ~= target and have.pureDrones < sd then
      job = buildDroneJob(X, A, B)
    elseif have.purePrincesses < sp then
      job = buildPrincessJob(X, A, B)
    end
    if job then return job end
    -- X's bank is at target (or nothing here advances it) -> continue up the tree.
  end

  -- Every bank looks satisfied yet the target isn't reached -- shouldn't happen
  -- with a well-formed plan; report so the caller re-plans rather than spins.
  return { type = "blocked", need = "no actionable job (replan)" }
end

return M
