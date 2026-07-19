--[[
  Bee Breeding Selection Module
  ------------------------------
  Assumes perfect information (all genotypes fully inspectable).

  Field names (active/inactive, not allele1/allele2) match the real Forestry
  genome layout as seen through OpenComputers/gendustry: an analyzed bee
  exposes `individual.active[trait]` and `individual.inactive[trait]` for
  each chromosome. Mirroring that here means genotypes read off a real bee
  (via beeManager.lua-style scanning) can be fed straight into this module
  with no translation step for the allele slots themselves.

  GENOTYPE FORMAT:
    genotype = {
      [traitName] = { active = "good"|"bad", inactive = "good"|"bad" },
      ...
    }

  TRAITS TRACKED: any chromosome the project cares about, using the same
  real names Forestry/gendustry uses -- e.g. "fertility", "speed",
  "lifespan", "territory", "flowering", "temperatureTolerance",
  "humidityTolerance", "caveDwelling", "nocturnal", "tolerantFlyer",
  "flowerProvider", "effect".

  SPECIES AS A TRAIT: in the real genome, species is just another
  chromosome with its own active/inactive alleles (a bee's actual species
  identity is active.species / inactive.species, a name string) -- it is
  not structurally different from fertility or speed. This module tracks
  it the exact same way: include "species" in traitList like any other
  trait, with its allele values pre-reduced to "good" (matches whatever
  species the current project is breeding toward) or "bad" (anything
  else). That reduction -- deciding what "good" means for species on a
  given project, i.e. the target species -- happens wherever genotypes are
  built/normalized before reaching this module (not in here); scoreDrone,
  selectBestDrone, shouldBank, and planGeneration all already work over an
  arbitrary traitList and don't need to know species is special.

  BEE FORMAT:
    bee = {
      id = <unique id/string>,
      genotype = <genotype table>,
    }

  TRAIT STATE (for princess or any bee, computed on the fly):
    "GG" -> homozygous good   (both alleles good)
    "Gb" -> heterozygous      (one good, one bad) -- good phenotype, not fixed
    "bb" -> homozygous bad    (both alleles bad)
--]]

local M = {}

-- ============================================================
-- Utility: classify a bee's state at a single trait
-- ============================================================
local function traitState(genotype, traitName)
  local t = genotype[traitName]
  if not t then
    error("Missing trait '" .. traitName .. "' in genotype")
  end
  local activeGood = (t.active == "good")
  local inactiveGood = (t.inactive == "good")
  if activeGood and inactiveGood then
    return "GG"
  elseif activeGood or inactiveGood then
    return "Gb"
  else
    return "bb"
  end
end
M.traitState = traitState

-- Does this bee carry at least one good allele at this trait?
local function hasGoodAllele(genotype, traitName)
  local state = traitState(genotype, traitName)
  return state == "GG" or state == "Gb"
end
M.hasGoodAllele = hasGoodAllele

-- ============================================================
-- 1. SCORING FUNCTION
--    Score a single candidate drone against the current princess,
--    given the list of traits being tracked.
-- ============================================================
--
-- traitList: array of trait name strings, e.g. {"speed","fertility","color"}
-- princessGenotype: genotype table for the current princess
-- drone: bee object (id + genotype)
-- endgameMode: unused, kept as a parameter for backwards compatibility with
--              existing call sites; scoring is unified across phases.
--              Filling total gaps (bb) is weighted highest since those
--              alleles can be permanently lost if never captured;
--              reinforcing Gb toward GG is weighted second; preserving an
--              already-GG trait gets only a small bonus (see isSafeDrone's
--              docs for why this is deliberately soft, not a hard veto).
--
-- Returns: numeric score (higher = better choice for this generation's cross)
--
function M.scoreDrone(traitList, princessGenotype, drone, endgameMode)
  local score = 0

  -- The "preserve an already-GG trait" bonus below is deliberately divided
  -- by trait count so its TOTAL, summed across every already-fixed trait,
  -- can never exceed a small constant (~0.5) regardless of how many traits
  -- the project tracks. Without this normalization, a per-trait bonus adds
  -- up linearly with N while the bb-gap-filling bonus (4) stays fixed --
  -- past around 9-10 already-fixed traits, "preserve everything" would
  -- mathematically outscore "introduce the one missing trait," recreating
  -- a permanent deadlock (confirmed via simulation at N=10 traits before
  -- this fix). Bounding the total keeps real progress always dominant.
  local preserveBonusPerTrait = 0.5 / #traitList

  for _, trait in ipairs(traitList) do
    local pState = traitState(princessGenotype, trait)
    local dState = traitState(drone.genotype, trait)

    if pState == "bb" then
      -- Critical gap: any good allele from drone is high value.
      if dState == "GG" then
        score = score + 4   -- best possible: guarantees a good allele passes on
      elseif dState == "Gb" then
        score = score + 3
      end
    elseif pState == "Gb" then
      -- Needs reinforcement toward GG.
      if dState == "GG" then
        score = score + 2   -- guarantees offspring gets a good allele here;
                             -- 50% chance of full GG lock-in this generation
      elseif dState == "Gb" then
        score = score + 1
      end
      -- dState == "bb" contributes 0 (drone offers nothing new here)
    elseif pState == "GG" then
      -- Already fixed. Small bonus (not a requirement) for a drone that's
      -- also GG here, nudging selection toward preserving it -- but a
      -- drone that would de-fix this trait can still win on other traits'
      -- weight, which is intentional (see isSafeDrone's docs).
      if dState == "GG" then
        score = score + preserveBonusPerTrait
      end
    end
  end

  return score
end

-- ============================================================
-- 2. SELECTION FUNCTION
--    Given the princess and a pool of candidate drones, pick the best one.
-- ============================================================
--
-- traitList: array of trait names
-- princessGenotype: genotype table
-- dronePool: array of bee objects
-- endgameMode: boolean (see scoreDrone)
--
-- Returns: bestDrone (bee object), bestScore (number), allScores (array of {drone, score} for inspection)
--
-- isSafeDrone: true if breeding this drone in cannot regress any locus the
-- princess has already fixed to GG (both parents would need to be GG there
-- for the trait to survive, since the princess is replaced by a fresh
-- random recombination each generation, not "selfed").
--
-- NOTE: this is informational only, not a selection filter. An earlier
-- version hard-vetoed any "unsafe" drone, but that creates a permanent
-- deadlock whenever the only drones carrying a still-missing (bb) trait's
-- good allele are, by necessity, unsafe everywhere else -- e.g. two
-- founding pure-breeding species that are each all-good but for a
-- different single trait. No drone can ever introduce the missing trait
-- without touching an already-fixed one, so a hard veto blocks all
-- progress forever (confirmed via simulation). Protection instead comes
-- from scoreDrone's own small GG-preservation bonus plus keeping enough
-- redundant good-allele carriers banked (see shouldBank's minCopies) that
-- a safe option is normally available anyway.
function M.isSafeDrone(traitList, princessGenotype, drone)
  for _, trait in ipairs(traitList) do
    local pState = traitState(princessGenotype, trait)
    if pState == "GG" then
      local dState = traitState(drone.genotype, trait)
      if dState ~= "GG" then
        return false
      end
    end
  end
  return true
end

function M.selectBestDrone(traitList, princessGenotype, dronePool, endgameMode)
  if #dronePool == 0 then
    return nil, 0, {}
  end

  local allScores = {}
  local bestDrone, bestScore = nil, -math.huge

  for _, drone in ipairs(dronePool) do
    local s = M.scoreDrone(traitList, princessGenotype, drone, endgameMode)
    table.insert(allScores, { drone = drone, score = s, safe = M.isSafeDrone(traitList, princessGenotype, drone) })

    if s > bestScore then
      bestScore = s
      bestDrone = drone
    end
  end

  return bestDrone, bestScore, allScores
end

-- ============================================================
-- 3. BANK vs DISCARD FUNCTION
--    Decide whether to keep a drone in storage or discard it, based on
--    whether it's still one of the few known DRONE sources of a good
--    allele for some trait -- checked across EVERY trait, including ones
--    the princess currently shows as GG.
-- ============================================================
--
-- Liberal-banking rationale: the princess is replaced by a single blind
-- random recombination each generation (no picking among candidates), so
-- a trait that's GG today can drop to Gb/bb tomorrow purely by chance. If
-- the drone pool has already discarded every other good-allele carrier for
-- that trait by then, the trait is gone forever -- no amount of further
-- breeding can bring it back. The princess herself is NOT counted as a
-- source here, precisely because she's the one at risk of randomly losing
-- it; insurance has to live in the drone pool.
--
-- minCopies (default 2): how many independent drone-sources of a good
-- allele to keep on hand for EVERY trait at all times, regardless of
-- whether the princess is currently bb/Gb/GG there. Raise it for more
-- insurance at the cost of holding onto more drones; 1 reduces to "keep a
-- drone only if it's the unique/last known source."
--
-- traitList: array of trait names
-- drone: candidate bee to evaluate
-- princessGenotype: current princess genotype (kept for API symmetry; not
--                    counted as a source -- see above)
-- bankedDrones: array of bee objects already in storage
-- chosenDroneForBreeding: the drone selected this round by selectBestDrone.
--                         NOT counted as a source (see below) -- it's only
--                         passed so it can be excluded from bank/discard.
-- minCopies: optional, defaults to 2
--
-- Returns: true (bank it) or false (discard it), plus a reason string
--
function M.shouldBank(traitList, drone, princessGenotype, bankedDrones, chosenDroneForBreeding, minCopies)
  minCopies = minCopies or 2

  -- Never need to bank the drone that's about to be bred (it's consumed).
  if chosenDroneForBreeding and drone.id == chosenDroneForBreeding.id then
    return false, "consumed_in_breeding"
  end

  -- chosenDroneForBreeding is deliberately NOT counted as a source below,
  -- even though its alleles do propagate into the next litter/princess.
  -- That propagation is only probabilistic (e.g. a Gb carrier only passes
  -- the good allele on ~50% of the time), whereas an actually-retained
  -- bankedDrones entry is a certain, still-available source next round.
  -- Counting the about-to-be-consumed drone as equivalent to a real banked
  -- copy understates how much insurance is really being kept, which was
  -- observed (via simulation) to let minCopies=2 silently degrade to just
  -- one real backup -- rare, but enough to occasionally lose a trait for
  -- good. Requiring minCopies real, persisting copies closes that gap.
  for _, trait in ipairs(traitList) do
    local dState = traitState(drone.genotype, trait)

    if dState == "GG" or dState == "Gb" then
      local sources = 0

      for _, banked in ipairs(bankedDrones) do
        local bState = traitState(banked.genotype, trait)
        if bState == "GG" or bState == "Gb" then
          sources = sources + 1
        end
      end

      if sources < minCopies then
        return true, "insurance_copy_for_trait:" .. trait
      end
    end
  end

  return false, "redundant_no_unique_value"
end

-- ============================================================
-- Convenience: run one full generational decision cycle
-- ============================================================
--
-- Returns a table describing what to do:
--   {
--     breedWith = <bee>,
--     score = <number>,
--     toBank = { <bee>, <bee>, ... },
--     toDiscard = { <bee>, <bee>, ... },
--   }
--
-- minCopies: optional, forwarded to shouldBank (default 2 -- see its docs).
--
function M.planGeneration(traitList, princessGenotype, dronePool, bankedDrones, endgameMode, minCopies)
  local best, bestScore = M.selectBestDrone(traitList, princessGenotype, dronePool, endgameMode)

  local toBank, toDiscard = {}, {}

  -- IMPORTANT: decisions are made sequentially, and each drone's redundancy
  -- check considers bankedDrones PLUS every drone already confirmed for
  -- banking earlier in this same pass. Without this, N identical copies of
  -- the same valuable drone would each see "the others" as already
  -- providing enough sources and all N could be discarded, losing the
  -- trait entirely. Processing sequentially and accumulating confirmed
  -- keeps at least minCopies of each still-needed source alive.
  local runningBank = {}
  for _, d in ipairs(bankedDrones) do table.insert(runningBank, d) end

  for _, drone in ipairs(dronePool) do
    if best and drone.id == best.id then
      -- will be consumed in breeding, not a bank/discard decision
    else
      local bank, reason = M.shouldBank(traitList, drone, princessGenotype, runningBank, best, minCopies)
      if bank then
        table.insert(toBank, { drone = drone, reason = reason })
        table.insert(runningBank, drone)
      else
        table.insert(toDiscard, { drone = drone, reason = reason })
      end
    end
  end

  return {
    breedWith = best,
    score = bestScore,
    toBank = toBank,
    toDiscard = toDiscard,
  }
end

-- ============================================================
-- Helper: check if princess is phenotypically all-good (for endgameMode trigger)
-- ============================================================
function M.isPhenotypicallyPerfect(traitList, genotype)
  for _, trait in ipairs(traitList) do
    if traitState(genotype, trait) == "bb" then
      return false
    end
  end
  return true
end

-- Helper: check if princess is fully homozygous-good (true purebred)
function M.isPurebred(traitList, genotype)
  for _, trait in ipairs(traitList) do
    if traitState(genotype, trait) ~= "GG" then
      return false
    end
  end
  return true
end

return M
