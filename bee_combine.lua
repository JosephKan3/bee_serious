--[[
  Bee Combine -- serial trait imprinting (pure)
  ---------------------------------------------
  The perfect phase's combine: breed a species-X-pure bee that ALSO carries the
  maxed allele set (every coverable trait homozygous-good), given a pool that has
  X (bad traits) and the all-good MAX donor (a different species).

  Doing all loci at once gets trapped in a local optimum (X-hybrid bees with many
  good traits that can't reach X-pure without losing them) -- measured plateaus
  of 0/9-4/9. The fix, validated at the crossRaw level (see
  docs/perfect_combine_design.md), is SERIAL IMPRINTING with PARTIAL-CREDIT
  scoring:

    - activate loci incrementally: species, then +trait1, +trait2, ...; fully fix
      (homozygous) the active set before adding the next trait;
    - score a bee by its count of CORRECT ALLELES over the active loci (0/1/2 per
      locus) -- heterozygous-good carriers score partway, so they're kept (they
      are exactly what you homozygize from; a homozygous-only score discards them).

  Pure and decoupled: species identity and "good" are injected. Operates on raw
  genotypes shaped like bee_keeper_sim.crossRaw / a normalized analyzed bee:
    g.species = { active = <speciesVal>, inactive = <speciesVal> }
    g[trait]  = { active = <rawVal>,     inactive = <rawVal> }        (per trait)

  opts = { target, traitOrder, isGood(trait,val), speciesKey(speciesVal) }
--]]

local M = {}

local function speciesGood(g, opts, which)
  return opts.speciesKey(g.species[which]) == opts.target
end
local function traitGood(g, trait, opts, which)
  return opts.isGood(trait, g[trait][which]) and true or false
end

-- Correct alleles a bee has over {species} + traits[1..n] (0/1/2 per locus).
function M.correctAlleles(g, n, opts)
  local s = 0
  if speciesGood(g, opts, "active") then s = s + 1 end
  if speciesGood(g, opts, "inactive") then s = s + 1 end
  for i = 1, n do
    local t = opts.traitOrder[i]
    if traitGood(g, t, opts, "active") then s = s + 1 end
    if traitGood(g, t, opts, "inactive") then s = s + 1 end
  end
  return s
end

local function speciesHom(g, opts)
  return speciesGood(g, opts, "active") and speciesGood(g, opts, "inactive")
end
local function traitHom(g, trait, opts)
  return traitGood(g, trait, opts, "active") and traitGood(g, trait, opts, "inactive")
end

-- Is this bee species-X-pure AND homozygous-good on traits[1..n]?
function M.meetsStage(g, n, opts)
  if not speciesHom(g, opts) then return false end
  for i = 1, n do
    if not traitHom(g, opts.traitOrder[i], opts) then return false end
  end
  return true
end

-- The current STAGE over a pool: the largest k (0..#traitOrder) for which some
-- bee is species-pure AND traits[1..k] all homozygous-good. Work targets trait
-- k+1 next; k == #traitOrder means the perfect bee exists (done).
function M.stage(bees, opts)
  local best = 0
  for _, g in ipairs(bees or {}) do
    if speciesHom(g, opts) then
      local k = 0
      for i = 1, #opts.traitOrder do
        if traitHom(g, opts.traitOrder[i], opts) then k = i else break end
      end
      if k > best then best = k end
    end
  end
  return best
end

-- Whether a perfect bee (species-pure + every trait homozygous-good) exists.
function M.isDone(bees, opts)
  return M.stage(bees, opts) >= #opts.traitOrder
end

-- Choose the next pair to breed: the two highest by correct-allele count over the
-- WORKING active set (species + traits[1..stage+1]) -- so the current trait's
-- good allele (carried by the donor, high-scoring) gets bred in, while already-
-- fixed loci are protected by their partial-credit weight. Returns
--   { done = true }                              when perfect,
--   { princess, drone, stage, working } otherwise (drone == princess if only one).
function M.selectPair(bees, opts)
  local s = M.stage(bees, opts)
  if s >= #opts.traitOrder then return { done = true } end
  local working = s + 1 -- include the trait being imprinted now
  local ranked = {}
  for _, g in ipairs(bees or {}) do ranked[#ranked + 1] = g end
  table.sort(ranked, function(p, q)
    return M.correctAlleles(p, working, opts) > M.correctAlleles(q, working, opts)
  end)
  if #ranked == 0 then return { done = false } end
  return { princess = ranked[1], drone = ranked[2] or ranked[1], stage = s, working = working }
end

return M
