--[[
  Bee Genebank
  -------------
  Pure module (no hardware/storage access) encoding the per-species RESERVE
  policy that keeps a breeding program from ever LOSING a species -- the fix
  for multi-step mutation "species drift" (crossing two species yields
  heterozygous offspring, so a continuously-consumed base line degrades and is
  eventually lost; see the Cultivated stall in fast_debug / v0.3 design memo).

  THE RESERVE (per species): keep >= 1 purebred (species-homozygous) PRINCESS
  and >= N purebred DRONES (N default 8). The drones are the recovery
  reservoir: a mutation cross A x B necessarily consumes A's princess and
  leaves a heterozygous replacement, so A's pure line can only be REBUILT by
  re-purifying that replacement against pure A drones (ordinary species-mode
  breeding). Hence the asymmetry below:

    - A DRONE is only ever spent from SURPLUS (pureDrones > minDrones) -- the
      reservoir itself is never touched, or there'd be nothing to recover with.
    - A PRINCESS may be spent down to zero (a mutation has to consume it), but
      ONLY when the drone reservoir is intact (>= minDrones), because that's
      what guarantees the species can be re-purified afterward. If the reservoir
      isn't there, the species must be replenished BEFORE it's used as a
      princess parent, or using it risks losing it for good.

  This module makes those decisions over a plain snapshot of holdings; it knows
  nothing about genomes, inventories, or storage. The caller (manager) classifies
  each held bee into { species, role, speciesPure } and consumes the verdicts.
  Kept pure and data-in/data-out so it's fully testable off-hardware, same as
  bee_breeding.lua / bee_mutation_graph.lua.
--]]

local M = {}

-- Reserve floor. "Pure" throughout means species-homozygous (the species locus
-- is GG for that species) -- quality-trait purity ("perfect" bees) is a later
-- concern layered on top, not part of the loss-prevention reserve.
M.DEFAULT_MIN_PRINCESSES = 1
M.DEFAULT_MIN_DRONES = 8

local function opt(opts, key, default)
  local v = opts and opts[key]
  if v == nil then return default end
  return v
end

function M.minPrincesses(opts) return opt(opts, "minPrincesses", M.DEFAULT_MIN_PRINCESSES) end
function M.minDrones(opts) return opt(opts, "minDrones", M.DEFAULT_MIN_DRONES) end

-- ============================================================
-- Summarize a holdings snapshot
-- ============================================================

-- entries: array of { species=<string>, role="princess"|"drone", speciesPure=<bool> }
--   role       -- from the item type (princess/queen vs drone).
--   speciesPure -- species locus homozygous for `species` (BB.isPurebred over
--                  just the species trait). Only pure specimens count toward the
--                  reserve; impure ones are drift/work-in-progress, tracked
--                  separately so the caller can see there's material to purify.
-- Returns: { [species] = { princesses, drones, purePrincesses, pureDrones,
--                          impurePrincesses, impureDrones } }
function M.summarize(entries)
  local by = {}
  local function rec(species)
    local s = by[species]
    if not s then
      s = { princesses = 0, drones = 0, purePrincesses = 0, pureDrones = 0,
            impurePrincesses = 0, impureDrones = 0 }
      by[species] = s
    end
    return s
  end
  for _, e in ipairs(entries or {}) do
    if e.species and e.role then
      local s = rec(e.species)
      if e.role == "princess" then
        s.princesses = s.princesses + 1
        if e.speciesPure then s.purePrincesses = s.purePrincesses + 1
        else s.impurePrincesses = s.impurePrincesses + 1 end
      elseif e.role == "drone" then
        s.drones = s.drones + 1
        if e.speciesPure then s.pureDrones = s.pureDrones + 1
        else s.impureDrones = s.impureDrones + 1 end
      end
    end
  end
  return by
end

-- Per-species record, with zeros for a species not held at all.
function M.statusOf(summary, species)
  return summary[species] or {
    princesses = 0, drones = 0, purePrincesses = 0, pureDrones = 0,
    impurePrincesses = 0, impureDrones = 0,
  }
end

-- ============================================================
-- Reserve predicates
-- ============================================================

-- The species' reserve is fully stocked: >= minPrincesses pure princesses AND
-- >= minDrones pure drones. This is the "safe, will never be lost" state.
function M.isSecure(summary, species, opts)
  local s = M.statusOf(summary, species)
  return s.purePrincesses >= M.minPrincesses(opts) and s.pureDrones >= M.minDrones(opts)
end

-- May a pure DRONE of this species be spent (as a mutation's allele2 parent)
-- right now? Only from surplus -- the reservoir itself is protected.
function M.canSpendDrone(summary, species, opts)
  return M.statusOf(summary, species).pureDrones > M.minDrones(opts)
end

-- May a pure PRINCESS of this species be spent (as a mutation's allele1 parent)
-- right now? Allowed to draw the line down to zero, but ONLY while the drone
-- reservoir is intact (>= minDrones) so the species can be re-purified from it
-- afterward -- that intact reservoir is exactly what prevents permanent loss.
function M.canSpendPrincess(summary, species, opts)
  local s = M.statusOf(summary, species)
  return s.purePrincesses >= 1 and s.pureDrones >= M.minDrones(opts)
end

-- How far below the reserve floor a species sits (0/0 when secure). Drives the
-- lazy same-species replenishment: build these back up before (or instead of)
-- drawing the species down further.
function M.deficit(summary, species, opts)
  local s = M.statusOf(summary, species)
  return {
    princesses = math.max(0, M.minPrincesses(opts) - s.purePrincesses),
    drones = math.max(0, M.minDrones(opts) - s.pureDrones),
  }
end

-- Whether a species needs replenishing (below floor on either count).
function M.needsReplenish(summary, species, opts)
  local d = M.deficit(summary, species, opts)
  return d.princesses > 0 or d.drones > 0
end

-- Can this species be replenished/purified at all from what's on hand? Rebuilding
-- a pure line needs breeding material of that species: at minimum one princess of
-- it (pure or impure -- an impure one is purified back against pure drones) AND
-- at least one pure drone to purify toward. Without any princess, or without a
-- pure drone to converge on, the species can't be regrown here and the user has
-- to supply more (a base leaf) -- the caller surfaces that.
function M.canReplenish(summary, species)
  local s = M.statusOf(summary, species)
  local hasPrincess = (s.purePrincesses + s.impurePrincesses) >= 1
  return hasPrincess and s.pureDrones >= 1
end

-- ============================================================
-- Draw plan for a directional mutation step (princessSpecies x droneSpecies)
-- ============================================================

-- Decides, for one mutation step, whether the reserves permit taking the
-- parents now, and if not, what to do. Pure: the caller passes the summary and
-- the two parent species; this returns a verdict it can act on.
--
-- Returns {
--   ready       = bool,                      -- both parents drawable now
--   replenish   = { species, ... },          -- species to top up first (secure them)
--   unrecoverable = { species, ... },        -- below floor AND cannot be regrown here
--                                            --   (user must supply this base leaf)
-- }
function M.planStepDraw(summary, princessSpecies, droneSpecies, opts)
  local replenish, unrecoverable = {}, {}
  local seen = {}
  local function consider(species, canSpend)
    if seen[species] then return end
    seen[species] = true
    if canSpend then return end
    if M.canReplenish(summary, species) then
      table.insert(replenish, species)
    else
      table.insert(unrecoverable, species)
    end
  end
  consider(princessSpecies, M.canSpendPrincess(summary, princessSpecies, opts))
  consider(droneSpecies, M.canSpendDrone(summary, droneSpecies, opts))
  return {
    ready = #replenish == 0 and #unrecoverable == 0,
    replenish = replenish,
    unrecoverable = unrecoverable,
  }
end

return M
