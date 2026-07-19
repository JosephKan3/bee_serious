--[[
  Bee Breeding Simulation Test Runner
  ------------------------------------
  Drives bee_breeding.lua's planGeneration() through a simulated genetics
  engine (independent-assortment Mendelian inheritance, resolved trait by
  trait) across many randomized trials, checking three things:

    1. Convergence      - does the princess line reach full purebred (all GG)
                          within a reasonable number of generations?
    2. Permanent loss   - does a trait's good allele ever vanish from the
                          ENTIRE known population (princess + every banked
                          drone), making it unrecoverable no matter how long
                          you keep breeding? (A single bad princess roll that
                          drops a trait to bb is fine and expected -- see
                          below -- as long as some drone still carries a
                          good allele there to fix it back.)
    3. No stagnation    - does the algorithm ever get stuck breeding the same
                          genotype forever without making progress?

  SCENARIO MODELED (matches the motivating question):
    Species A (the starting princess): good at every trait except one.
    Species B: good at exactly that one trait, bad at everything else.

  Per "you have an infinite amount of drones from both species" in the very
  first generation, generation 1's drone pool gets a configurable number of
  fresh copies of BOTH pure species injected (pureStockCount each), on top
  of whatever is banked. From generation 2 onward, the only drones available
  are whatever was banked plus the litter just produced -- no more free pure
  stock -- matching the "keep breeding, but manage what you have" premise.

  PRINCESS SUCCESSION (confirmed): the next princess is a single, blind,
  uncontrollable random offspring of (old princess x chosen drone) -- there
  is no "choose the best of several candidate princesses" step the way there
  is for drones. That means a trait can occasionally regress by pure chance
  (e.g. crossing two Gb parents at a locus is only 25% likely to land GG,
  50% Gb, 25% bb) with nothing in the algorithm able to prevent that specific
  roll. So a single regression event is not a failure; only losing the
  allele from the whole population is.
--]]

local BB = require("bee_breeding")

-- ============================================================
-- Genetics engine
-- ============================================================

local function deepCopyGenotype(genotype)
  local copy = {}
  for trait, alleles in pairs(genotype) do
    copy[trait] = { allele1 = alleles.allele1, allele2 = alleles.allele2 }
  end
  return copy
end

-- A parent contributes ONE of its two alleles per trait, chosen 50/50.
local function pickAllele(alleles)
  if math.random() < 0.5 then
    return alleles.allele1
  else
    return alleles.allele2
  end
end

-- Independent assortment: each trait's inheritance is resolved separately.
local function crossGenotype(traitList, genotypeA, genotypeB)
  local child = {}
  for _, trait in ipairs(traitList) do
    child[trait] = {
      allele1 = pickAllele(genotypeA[trait]),
      allele2 = pickAllele(genotypeB[trait]),
    }
  end
  return child
end

-- Every trait in goodTraits (a set: name -> true) is homozygous good;
-- everything else is homozygous bad.
local function makeGenotype(traitList, goodTraits)
  local genotype = {}
  for _, trait in ipairs(traitList) do
    if goodTraits[trait] then
      genotype[trait] = { allele1 = "good", allele2 = "good" }
    else
      genotype[trait] = { allele1 = "bad", allele2 = "bad" }
    end
  end
  return genotype
end

local function traitSummary(traitList, genotype)
  local parts = {}
  for _, trait in ipairs(traitList) do
    table.insert(parts, trait .. "=" .. BB.traitState(genotype, trait))
  end
  return table.concat(parts, " ")
end

local function genotypeStateKey(traitList, genotype)
  local parts = {}
  for _, t in ipairs(traitList) do
    table.insert(parts, BB.traitState(genotype, t))
  end
  return table.concat(parts, ",")
end

-- ============================================================
-- Single trial
-- ============================================================
--
-- IMPORTANT MECHANIC (confirmed): the next princess is a single, blind,
-- uncontrollable random offspring -- there is no "pick the best of several
-- candidate princesses" step. Only drones are inspectable/selectable.
-- Combined with "assume you can keep breeding," this means a single bad
-- princess roll that drops some trait to bb is NOT itself a failure -- it's
-- expected to happen sometimes by chance, and recoverable as long as some
-- drone still carries a good allele there. The only TRUE, permanent failure
-- is a trait going bb in the princess while simultaneously NO drone in the
-- entire available pool carries a good allele for it -- at that point the
-- allele is gone from the whole known population and no amount of further
-- breeding can ever bring it back.
--
-- opts:
--   litterSize        drones produced per breeding event (default 6)
--   pureStockCount    copies of EACH pure species injected at gen 1 (default 6)
--   maxGenerations    safety cap (default 400 -- random-princess recovery can
--                     take a while, especially as trait count grows)
--   stagnationLimit   consecutive generations with zero genotype change
--                     before declaring the trial permanently stuck (default
--                     30). Once every trait but one is fixed, resolving the
--                     last one is basically a repeated 50/50 coin flip, so
--                     "no change for k generations" happens by pure chance
--                     with probability ~0.5^k -- NOT a deadlock. Confirmed
--                     by replay: a trial flagged stuck at 15 (~1/2^15 odds,
--                     genuinely rare but not negligible across thousands of
--                     trials) converged fine by generation 32 when given
--                     more patience. 30 keeps false positives astronomically
--                     rare (~1/2^30) while still catching a REAL deadlock
--                     (which shows literally zero change forever, so any
--                     threshold catches it eventually).
--   verbose           print a generation-by-generation log
--
local function runTrial(traitList, badTrait, opts)
  opts = opts or {}
  local litterSize = opts.litterSize or 6
  local pureStockCount = opts.pureStockCount or 6
  local maxGenerations = opts.maxGenerations or 400
  local stagnationLimit = opts.stagnationLimit or 30
  local verbose = opts.verbose or false

  local goodSetA = {}
  for _, t in ipairs(traitList) do
    if t ~= badTrait then goodSetA[t] = true end
  end
  local goodSetB = { [badTrait] = true }

  local speciesA = makeGenotype(traitList, goodSetA)
  local speciesB = makeGenotype(traitList, goodSetB)

  local princessGenotype = deepCopyGenotype(speciesA)
  local bankedDrones = {}
  local idCounter = 0
  local function nextId(prefix)
    idCounter = idCounter + 1
    return prefix .. idCounter
  end

  local lastKey = genotypeStateKey(traitList, princessGenotype)
  local stagnantStreak = 0
  local phenotypeLossEvents = 0
  local phenotypeRecoveryEvents = 0

  if verbose then
    print(string.format("[trial] bad trait = %s | traits = %s", badTrait, table.concat(traitList, ",")))
    print(string.format("gen 0: princess [%s]", traitSummary(traitList, princessGenotype)))
  end

  for gen = 1, maxGenerations do
    if BB.isPurebred(traitList, princessGenotype) then
      return { success = true, generations = gen - 1, stuck = false, permanentLoss = false,
               phenotypeLossEvents = phenotypeLossEvents, phenotypeRecoveryEvents = phenotypeRecoveryEvents }
    end

    -- This generation's pool: everything banked, plus (gen 1 only) fresh
    -- "infinite" pure stock of both starting species.
    local dronePool = {}
    for _, d in ipairs(bankedDrones) do table.insert(dronePool, d) end
    if gen == 1 then
      for i = 1, pureStockCount do
        table.insert(dronePool, { id = nextId("pureA"), genotype = deepCopyGenotype(speciesA) })
      end
      for i = 1, pureStockCount do
        table.insert(dronePool, { id = nextId("pureB"), genotype = deepCopyGenotype(speciesB) })
      end
    end

    local statesBefore = {}
    for _, t in ipairs(traitList) do statesBefore[t] = BB.traitState(princessGenotype, t) end

    local endgame = BB.isPhenotypicallyPerfect(traitList, princessGenotype)
    local plan = BB.planGeneration(traitList, princessGenotype, dronePool, {}, endgame)

    if not plan.breedWith then
      return { success = false, generations = gen, stuck = true, permanentLoss = false,
               reason = "no_drone_available" }
    end

    if verbose then
      print(string.format("gen %d: princess [%s] | pool=%d | chose %s (score %.1f)",
        gen, traitSummary(traitList, princessGenotype), #dronePool, plan.breedWith.id, plan.score))
    end

    -- Litter + princess replacement are independent sibling draws from the
    -- same (princess, chosenDrone) mating pair. The princess draw is blind:
    -- nothing selects it, it's just whatever it rolls.
    local litter = {}
    for i = 1, litterSize do
      table.insert(litter, {
        id = nextId("g" .. gen .. "-"),
        genotype = crossGenotype(traitList, princessGenotype, plan.breedWith.genotype),
      })
    end
    local newPrincessGenotype = crossGenotype(traitList, princessGenotype, plan.breedWith.genotype)

    for _, t in ipairs(traitList) do
      local before = statesBefore[t]
      local after = BB.traitState(newPrincessGenotype, t)
      if before ~= "bb" and after == "bb" then phenotypeLossEvents = phenotypeLossEvents + 1 end
      if before == "bb" and after ~= "bb" then phenotypeRecoveryEvents = phenotypeRecoveryEvents + 1 end
    end

    -- Carry forward next generation's pool: survivors + fresh litter.
    bankedDrones = {}
    for _, entry in ipairs(plan.toBank) do table.insert(bankedDrones, entry.drone) end
    for _, d in ipairs(litter) do table.insert(bankedDrones, d) end

    princessGenotype = newPrincessGenotype

    -- Permanent-loss check: a trait is bb in the princess AND no drone
    -- anywhere in the pool carries a good allele for it. This can never be
    -- recovered by further breeding -- the allele is gone from the entire
    -- known population.
    for _, t in ipairs(traitList) do
      if BB.traitState(princessGenotype, t) == "bb" then
        local recoverable = false
        for _, d in ipairs(bankedDrones) do
          if BB.hasGoodAllele(d.genotype, t) then
            recoverable = true
            break
          end
        end
        if not recoverable then
          return { success = false, generations = gen, stuck = false, permanentLoss = true,
                   reason = "permanently_lost_allele:" .. t,
                   phenotypeLossEvents = phenotypeLossEvents, phenotypeRecoveryEvents = phenotypeRecoveryEvents }
        end
      end
    end

    local key = genotypeStateKey(traitList, princessGenotype)
    if key == lastKey then
      stagnantStreak = stagnantStreak + 1
    else
      stagnantStreak = 0
    end
    lastKey = key

    if stagnantStreak >= stagnationLimit then
      return { success = false, generations = gen, stuck = true, permanentLoss = false,
               reason = "no_genetic_change_for_" .. stagnationLimit .. "_generations",
               finalState = traitSummary(traitList, princessGenotype),
               phenotypeLossEvents = phenotypeLossEvents, phenotypeRecoveryEvents = phenotypeRecoveryEvents }
    end
  end

  if BB.isPurebred(traitList, princessGenotype) then
    return { success = true, generations = maxGenerations, stuck = false, permanentLoss = false,
             phenotypeLossEvents = phenotypeLossEvents, phenotypeRecoveryEvents = phenotypeRecoveryEvents }
  end

  return { success = false, generations = maxGenerations, stuck = true, permanentLoss = false,
           reason = "max_generations_reached", finalState = traitSummary(traitList, princessGenotype),
           phenotypeLossEvents = phenotypeLossEvents, phenotypeRecoveryEvents = phenotypeRecoveryEvents }
end

-- ============================================================
-- Batch runner + report
-- ============================================================

-- Derives a per-trial seed from a batch's base seed + trial index, so any
-- single trial within a large batch can be reseeded and replayed in
-- isolation later -- without this, reproducing e.g. trial #4821's exact
-- failure would require re-running all 4820 trials before it just to reach
-- the same point in one continuous random stream.
local function trialSeedFor(baseSeed, i)
  return (baseSeed * 1000003 + i) % 2147483647
end

local function runBatch(traitList, badTrait, trials, baseSeed, opts)
  local successCount, permanentLossCount, stuckCount = 0, 0, 0
  local genSum, genMin, genMax = 0, math.huge, -math.huge
  local lossEventSum, recoveryEventSum = 0, 0
  local reasonCounts = {}
  local failures = {}

  for i = 1, trials do
    local trialSeed = trialSeedFor(baseSeed, i)
    math.randomseed(trialSeed)
    local result = runTrial(traitList, badTrait, opts)
    lossEventSum = lossEventSum + (result.phenotypeLossEvents or 0)
    recoveryEventSum = recoveryEventSum + (result.phenotypeRecoveryEvents or 0)
    if result.success then
      successCount = successCount + 1
      genSum = genSum + result.generations
      if result.generations < genMin then genMin = result.generations end
      if result.generations > genMax then genMax = result.generations end
    else
      if result.permanentLoss then permanentLossCount = permanentLossCount + 1 end
      if result.stuck then stuckCount = stuckCount + 1 end
      local r = result.reason or "unknown"
      reasonCounts[r] = (reasonCounts[r] or 0) + 1
      if #failures < 10 then
        table.insert(failures, { index = i, seed = trialSeed, reason = r })
      end
    end
  end

  return {
    trials = trials,
    successCount = successCount,
    permanentLossCount = permanentLossCount,
    stuckCount = stuckCount,
    avgGenerations = successCount > 0 and (genSum / successCount) or nil,
    minGenerations = successCount > 0 and genMin or nil,
    maxGenerations = successCount > 0 and genMax or nil,
    avgLossEventsPerTrial = lossEventSum / trials,
    avgRecoveryEventsPerTrial = recoveryEventSum / trials,
    reasonCounts = reasonCounts,
    failures = failures,
  }
end

local function printBatchReport(label, report)
  print(string.format("== %s ==", label))
  print(string.format("  trials: %d | success: %d (%.1f%%) | permanent allele loss: %d | stuck: %d",
    report.trials, report.successCount, 100 * report.successCount / report.trials,
    report.permanentLossCount, report.stuckCount))
  print(string.format("  avg transient phenotype-loss events/trial: %.2f | avg recoveries/trial: %.2f",
    report.avgLossEventsPerTrial, report.avgRecoveryEventsPerTrial))
  if report.successCount > 0 then
    print(string.format("  generations to purebred -- avg: %.1f | min: %d | max: %d",
      report.avgGenerations, report.minGenerations, report.maxGenerations))
  end
  if report.stuckCount > 0 or report.permanentLossCount > 0 then
    print("  failure reasons:")
    for reason, count in pairs(report.reasonCounts) do
      print(string.format("    %-45s x%d", reason, count))
    end
    print("  reproduce a specific failure with: lua bee_breeding_test.lua <seed> <trialSeed>")
    for _, f in ipairs(report.failures) do
      print(string.format("    trial #%d (%s) -> trialSeed=%d", f.index, f.reason, f.seed))
    end
  end
end

-- ============================================================
-- Main
-- ============================================================

local seed = tonumber(arg and arg[1]) or os.time()
local traitList = { "fertility", "speed", "lifespan", "territory", "flowering", "tolerance" }
local badTrait = "fertility"

-- Second arg: replay one specific failing trial by its trialSeed (as printed
-- in a batch report's "reproduce a specific failure with..." lines), and
-- skip everything else. Lets you drill into a rare failure found at scale
-- without re-running the whole batch to reach it.
if arg and arg[2] then
  local trialSeed = tonumber(arg[2])
  math.randomseed(trialSeed)
  print(string.format("[replaying trialSeed=%d]", trialSeed))
  local result = runTrial(traitList, badTrait, { verbose = true })
  if result.success then
    print(string.format("RESULT: purebred in %d generations", result.generations))
  else
    print(string.format("RESULT: FAILED (%s)%s", result.reason or "unknown",
      result.finalState and (" | final state: " .. result.finalState) or ""))
  end
  return
end

math.randomseed(seed)
print(string.format("[seed=%d]", seed))
print("")

-- One verbose run so you can see the generation-by-generation decisions.
print("---- verbose single trial ----")
local verboseResult = runTrial(traitList, badTrait, { verbose = true })
if verboseResult.success then
  print(string.format("RESULT: purebred in %d generations\n", verboseResult.generations))
else
  print(string.format("RESULT: FAILED (%s)%s\n",
    verboseResult.reason or "unknown",
    verboseResult.finalState and (" | final state: " .. verboseResult.finalState) or ""))
end

-- Main batch: the exact motivating scenario, repeated many times.
local mainReport = runBatch(traitList, badTrait, 10000, seed)

printBatchReport("main scenario (6 traits, 'fertility' is the sole bad trait in the starting princess)", mainReport)
print("")

-- Robustness sweep: vary trait count and which trait is the "bad" one.
print("---- robustness sweep ----")
local sweepConfigs = {
  { traits = { "a", "b", "c" }, trials = 60 },
  { traits = { "a", "b", "c", "d", "e", "f", "g", "h" }, trials = 40 },
  { traits = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }, trials = 25 },
}

for cfgIdx, cfg in ipairs(sweepConfigs) do
  for badIdx, bad in ipairs(cfg.traits) do
    -- Offset the base seed per sub-config so different sweep configs don't
    -- reuse identical trial seeds against each other.
    local subSeed = seed + cfgIdx * 100003 + badIdx * 7919
    local report = runBatch(cfg.traits, bad, cfg.trials, subSeed)
    local label = string.format("N=%d traits, bad='%s'", #cfg.traits, bad)
    if report.successCount < report.trials then
      printBatchReport(label, report)
    end
  end
end
print("(sweep configs with 100% success across all bad-trait positions are omitted above for brevity)")

BB.isSafeDrone = originalIsSafeDrone
