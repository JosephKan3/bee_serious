--[[
  Bee Traitmax orchestrator (pure)
  --------------------------------
  Ties the traitmax pieces into the TWO-PHASE plan a traitmax project runs:

    Phase A "acquire"  -- bank a purebred of each DONOR species whose default
                          template supplies a good allele for some target trait
                          (bee_traitmax_mutation.selectDonors over the species
                          reachable from your base leaves). Reuses the rainbow /
                          genebank-scheduler machinery: the donor set IS the
                          target set to build bottom-up.
    Phase B "combine"  -- once every donor is banked, concentrate the good
                          alleles into one bee via the existing quality breeding.
                          SPECIES-AGNOSTIC: we only care about the alleles, not
                          what species the max bee ends up being.

  Pure and decoupled (no hardware): the manager owns the actual banking/breeding;
  this module only decides WHICH donors to acquire and WHICH phase we're in.
--]]

local rainbow = require("bee_rainbow")
local selectors = require("bee_traitmax_mutation")
local templatesMod = require("bee_templates")

local M = {}

-- Decide the donor species to acquire so their templates collectively supply a
-- good allele for every coverable trait.
--   graph          : bee_mutation_graph.build() result
--   ownedLeaves    : set { [species]=true } of base leaves held
--   parsedTemplates: bee_templates.load() result (Java-enum-keyed)
--   traitList      : traits to maximize (bee_trait_config.activeTraits(), no species)
--   isGood         : isGood(trait, rawValue) -> bool (bee_trait_config.isGoodValue)
--   bankedSpecies  : optional set of species already banked (treated as owned)
-- Returns:
--   { donorSet    = { [species]=true },   -- Phase A acquire targets
--     donors      = { species, ... },     -- sorted
--     perTrait    = { [trait]=species },   -- which donor supplies each trait
--     needed      = { species, ... },     -- donors not owned/banked -> mutate for
--     uncoverable = { trait, ... },        -- no reachable species is good at these
--     templates   = <live-display-name-keyed raw template map> }
function M.plan(graph, ownedLeaves, parsedTemplates, traitList, isGood, bankedSpecies)
  local reachable = rainbow.reachableTargets(graph, ownedLeaves)
  -- The base leaves themselves are donors too (already on hand).
  for sp in pairs(ownedLeaves or {}) do reachable[sp] = true end

  local liveMap = templatesMod.build(parsedTemplates, reachable)

  -- Owned for the greedy preference = base leaves + already-banked species.
  local owned = {}
  for sp in pairs(ownedLeaves or {}) do owned[sp] = true end
  for sp in pairs(bankedSpecies or {}) do owned[sp] = true end

  local sel = selectors.selectDonors(liveMap, traitList, isGood, owned)
  local donorSet = {}
  for _, sp in ipairs(sel.donors) do donorSet[sp] = true end

  return {
    donorSet = donorSet,
    donors = sel.donors,
    perTrait = sel.perTrait,
    needed = sel.needed,
    uncoverable = sel.uncoverable,
    templates = liveMap,
  }
end

-- Which phase the project is in, given which donor species are banked purebred.
-- "acquire" while any donor is still unbanked; "combine" once all are. The
-- manager decides "done" from the combine breeding result (a max bee is reached).
function M.phase(donorSet, banked)
  for sp in pairs(donorSet or {}) do
    if not (banked or {})[sp] then return "acquire" end
  end
  return "combine"
end

-- The next donor to bank in Phase A: shallowest-first over the donor set,
-- reusing rainbow's ordering (banked species + base leaves count as parents).
-- Returns nil when every donor is banked.
function M.nextDonor(graph, ownedLeaves, banked, donorSet)
  return rainbow.nextTarget(graph, ownedLeaves, banked, donorSet)
end

-- How many donors are still unbanked (Phase A progress).
function M.remaining(donorSet, banked)
  return rainbow.remaining(banked, donorSet)
end

return M
