--[[
  Bee Pool -- bounded, role-balanced, evolving breeding pool (pure)
  ----------------------------------------------------------------
  The perfect-phase combine breeds a species-X-pure bee that also carries the
  maxed allele set. Each mating yields 1 princess but SEVERAL drones, so an
  unmanaged cargo pool floods with drones: once cargo is full, offspring
  princesses have nowhere to land, the princess pool drains to zero, and the
  whole loop goes dead-flat (the documented 8/9 convergence tail -- see
  docs/perfect_combine_design.md).

  This module decides, each cycle, which cargo bees to KEEP in the active
  breeding pool and which to DISCARD to overflow storage, holding the pool at a
  bounded, role-balanced composition:

    * top `maxPrincess` princesses and top `maxDrone` drones by fitness -- a hard
      cap that keeps free cargo slots available for the next offspring;
    * `protect`ed bees (the renewable good-allele donor, an already-perfect bee)
      are always kept and do NOT consume a role cap -- the good-allele source and
      finished progress are never thrown away;
    * only a FEW working-trait carriers survive (the high-fitness ones), not all
      of them -- naive "never discard a carrier" over-protects when the trait is
      common (the donor spreads it widely), so nothing gets discarded and cargo
      stays full.

  Discards go to overflow storage, not the void, so genes aren't lost (storage
  can be restocked). Pure and decoupled: role and fitness are injected; items are
  opaque. Mirrors bee_combine's role -- planning logic testable off-hardware.

  opts = {
    isPrincess(item) -> bool,       -- role classifier
    fitness(item)    -> number,     -- higher is better
    maxPrincess, maxDrone,          -- per-role caps (>= 1)
    protect(item)    -> bool|nil,   -- optional: always keep, no cap slot
    rng()            -> [0,1)|nil,  -- optional: tie-break jitter for diversity
  }
--]]

local M = {}

local function score(item, opts)
  local f = opts.fitness(item) or 0
  -- Deterministic by default; a supplied rng adds a sub-unit jitter so ties are
  -- broken differently across cycles/apiaries (pairing diversity), never enough
  -- to reorder genuinely-different fitnesses.
  if opts.rng then f = f + opts.rng() * 0.5 end
  return f
end

-- Partition `pool` into keep/discard at the bounded, role-balanced composition.
-- Returns keep, discard (arrays, order not significant).
function M.balance(pool, opts)
  local princesses, drones, protectedKeep = {}, {}, {}
  for _, item in ipairs(pool or {}) do
    if opts.protect and opts.protect(item) then
      protectedKeep[#protectedKeep + 1] = item
    elseif opts.isPrincess(item) then
      princesses[#princesses + 1] = item
    else
      drones[#drones + 1] = item
    end
  end

  local function rank(list)
    table.sort(list, function(a, b) return score(a, opts) > score(b, opts) end)
  end
  rank(princesses)
  rank(drones)

  local keep, discard = {}, {}
  for _, item in ipairs(protectedKeep) do keep[#keep + 1] = item end
  local function take(list, cap)
    for i, item in ipairs(list) do
      if i <= cap then keep[#keep + 1] = item else discard[#discard + 1] = item end
    end
  end
  take(princesses, opts.maxPrincess)
  take(drones, opts.maxDrone)
  return keep, discard
end

-- How many princesses / drones are in the kept pool (roles as classified). Handy
-- for deciding whether the pool is starved of a role and needs a restock.
function M.roleCounts(pool, opts)
  local p, d = 0, 0
  for _, item in ipairs(pool or {}) do
    if opts.isPrincess(item) then p = p + 1 else d = d + 1 end
  end
  return p, d
end

return M
