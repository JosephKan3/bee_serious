--[[
  Bee Traitmax via Mutation
  --------------------------
  Pure module for the FOUNDATION of a perfect bee: you cannot assume a good allele
  for a trait exists in your starting stock -- good alleles are introduced by
  mutating to a SPECIES whose default template happens to carry one. So before you
  can breed a max-trait bee you must know which species carries a good allele for
  each trait, and mutate to acquire the ones you don't already have.

  This module answers exactly that, over a species->template map:

    templates = { [species] = { [trait] = alleleValue, ... }, ... }

  where each species' entry is its DEFAULT genome's quality alleles (what a freshly
  mutated purebred bee of that species has -- learned by analyzing the first
  specimen of each species, e.g. as rainbow mode banks them).

  It's pure and decoupled: judging an allele "good" is injected as
  isGood(trait, value) -> bool (the manager passes bee_trait_config.isGoodValue).

  Output is a DONOR set: the minimal group of species whose templates COLLECTIVELY
  supply a good allele for every coverable trait (a small set-cover, greedy,
  preferring species you already own). Breeding those donors together -- plus the
  target species -- is what yields a perfect bee. Traits no known species is good
  at are reported as uncoverable (you need a wider species pool / more mutations).
--]]

local M = {}

-- Species whose template carries a GOOD allele for `trait`.
function M.donorsForTrait(templates, trait, isGood)
  local set = {}
  for sp, tmpl in pairs(templates or {}) do
    local v = tmpl[trait]
    if v ~= nil and isGood(trait, v) then set[sp] = true end
  end
  return set
end

local function sortedList(set)
  local l = {}
  for k in pairs(set) do l[#l + 1] = k end
  table.sort(l)
  return l
end

-- Choose donor species covering every coverable trait, greedily minimizing NEW
-- acquisitions (species already owned are "free"). owned is an optional set.
-- Returns:
--   { donors      = { species, ... },        -- the chosen donor set (sorted)
--     perTrait    = { [trait] = species },    -- which donor covers each trait
--     needed      = { species, ... },         -- donors not currently owned -> MUTATE for these
--     uncoverable = { trait, ... } }          -- no known species is good at these
function M.selectDonors(templates, traitList, isGood, owned)
  owned = owned or {}

  -- goodAt[species] = set of traits it supplies; coverable = traits any species covers.
  local goodAt, coverable = {}, {}
  for _, trait in ipairs(traitList) do
    local donors = M.donorsForTrait(templates, trait, isGood)
    if next(donors) then coverable[trait] = true end
    for sp in pairs(donors) do
      goodAt[sp] = goodAt[sp] or {}
      goodAt[sp][trait] = true
    end
  end

  -- Greedy set cover over the coverable traits, prioritizing FEWEST NEW
  -- ACQUISITIONS (a mutation is expensive; an already-owned species is free). An
  -- owned donor that covers any still-uncovered trait always beats a new one --
  -- the bonus exceeds the largest possible coverage count -- so new species are
  -- only chosen for traits no owned species can supply. Within a class, higher
  -- coverage wins; sorted iteration breaks remaining ties deterministically.
  local ownedBonus = #traitList + 1
  local uncovered = {}
  for t in pairs(coverable) do uncovered[t] = true end
  local chosen, perTrait = {}, {}
  while next(uncovered) do
    local best, bestScore
    for _, sp in ipairs(sortedList(goodAt)) do
      if not chosen[sp] then
        local score = 0
        for t in pairs(goodAt[sp]) do if uncovered[t] then score = score + 1 end end
        if score > 0 then
          local adj = score + (owned[sp] and ownedBonus or 0)
          if not best or adj > bestScore then best, bestScore = sp, adj end
        end
      end
    end
    if not best then break end
    chosen[best] = true
    for t in pairs(goodAt[best]) do
      if uncovered[t] then perTrait[t] = best; uncovered[t] = nil end
    end
  end

  local needed = {}
  for _, sp in ipairs(sortedList(chosen)) do
    if not owned[sp] then needed[#needed + 1] = sp end
  end
  local uncoverable = {}
  for _, trait in ipairs(traitList) do
    if not coverable[trait] then uncoverable[#uncoverable + 1] = trait end
  end
  return {
    donors = sortedList(chosen),
    perTrait = perTrait,
    needed = needed,
    uncoverable = uncoverable,
  }
end

return M
