# Perfect-phase combine: serial trait imprinting (validated design)

The perfect phase makes each banked species X into a purebred bee that ALSO
carries the maxed allele set (all coverable traits homozygous-good). The good
alleles come from the traitmax **max bee**, which is a DIFFERENT species (Y).

## The problem

Species and traits are anti-correlated in the pool: X bees have bad traits; the
only good alleles live in the Y donor. Getting a bee that is X/X **and**
good/good on all ~9 traits means fixing ~10 loci homozygously at once. Greedy
per-generation selection over all loci at once gets trapped in a large local
optimum (X-hybrid bees with many good traits that can't reach X-pure without
sacrificing traits). Measured plateaus:

- Manager's species mode (all loci at once): **4/9 X-pure, dead-flat 320+ cycles.**
- Toy breeder, all loci at once, even with partial-credit allele scoring: **0/9.**
- Not donor exhaustion — plateaus identically with an infinitely renewable donor.

## The fix: serial trait imprinting (VALIDATED — reaches 9/9)

Activate loci INCREMENTALLY. Fix a small set fully (homozygous) before adding the
next trait, so the pool always contains fully-X-pure bees carrying the
already-fixed traits, and each step is a small achievable move.

```
activeLoci = { species }
for each trait T in coverable order:
    activeLoci += T
    breed toward "every locus in activeLoci homozygous-correct" until reached:
        fitness(bee) = sum over activeLoci of (# correct alleles, 0/1/2)   -- PARTIAL credit
        # correct = X for species; isGoodValue(t, allele) for a trait t
        each round: breed pairs drawn from {current pool} ∪ {the all-good donor},
                    keep the top-K offspring+pool by fitness
    # sub-goal reached: some pool bee has activeLoci all homozygous-correct
```

Two things are both necessary (each alone fails):
1. **Serial activation** — all-at-once never reaches X-pure here (0/9).
2. **Partial-credit allele scoring** — count individual correct alleles (0/1/2
   per locus), NOT just homozygous loci. Heterozygous-good carriers are exactly
   what you homozygize from; a GG-only score discards them. (The manager's
   `purityOf` counts GG loci only — likely why it plateaus.)

The donor must stay available every round (a renewable donor bank: donor×donor
stays all-good). It supplies the good alleles that species-X drones lack.

Validated in `scripts/` experiments (crossRaw-level): serial imprint reached
9/9 X-pure by trait 6 of 9; all-at-once variants reached 0/9–4/9.

## SOLVED (v0.5.1) -- full 9/9 via the bounded-pool subsystem (bee_pool.lua)

The one-trait tail is closed. It was never a scoring problem; it was breeding-loop
DYNAMICS, fixed by a bounded, role-balanced, evolving cargo pool plus adequate
analysis throughput. `bee_pool.lua` (pure) decides each visit which cargo bees to
KEEP and which to send to overflow storage; `pruneCombinePool` in the manager
wires it into `M.runPerfectSite`. Reaches 9/9 by ~cycle 20 in the e2e (was a
dead-flat 8/9 for 1000+ cycles).

Three compounding causes had to be fixed together -- each alone still froze:

1. **Prune must run UP FRONT every visit, not gated behind a mating completion.**
   A full cargo blocks seeding new matings, so nothing completes, so a
   completion-gated prune never runs again -- a hard deadlock. `pruneCombinePool`
   is the first thing `runPerfectSite` does, independent of apiary state.
2. **Protect ONLY a truly-finished perfect bee (species-pure AND all-good), never
   all-good SPECIES-HYBRIDS.** Once the donor's alleles spread, most of the pool
   is all-good-but-hybrid; protecting all of them leaves nothing discardable and
   cargo stays full (the documented over-protection failure mode, re-created if
   `protect = allGood`). Hybrids and donors compete on the role caps by fitness
   (top ~6 princesses + ~8 drones, `Combine.correctAlleles` over all traits).
3. **Analysis throughput (honey) must keep up.** Analyzing consumes honey;
   unanalyzed offspring are INVISIBLE to the genome-based pool and silently
   re-flood cargo. Real GTNH honey is renewable (harvested combs), so a live
   deployment must keep it stocked (the e2e models this). A safety valve also
   sheds surplus UNANALYZED drones under pressure, so a honey lag degrades
   gracefully (cargo held at the free-slot target, ~8/9) instead of hard-freezing.

Config knobs (defaults): `perfectMaxPrincess=6`, `perfectMaxDrone=8`,
`perfectMinFreeCargo=6` (prune trigger + free-slot target), `perfectMaxUnanalyzed=4`.
Discards go to `storagePos` (overflow, genes kept) or `trashPos` if no storage.

## History: v0.5.0 -- reached 8/9, one-trait tail (kept for context)

`M.runPerfectSite` drives the perfect phase with `bee_combine`. Two scoring rules
were essential (found by debugging the wiring):
1. **Fitness must dominate species purity.** A first cut weighted `xAlleles*100`
   so an X-pure bee always outranked an X-hybrid -- even one carrying the good
   allele the X line still lacked -- so the allele could never enter the pure
   line (stuck with flowerProvider bad). Fix: `fit*BIG + xAlleles` (species is a
   tiebreak only).
2. **The drone must always carry the working trait** (donor early, X-carriers
   once they have it) so the trait keeps flowing in while the princess protects
   the species line.

Result over the real manager+sim (foreign all-good donor into X-all-bad):
species-pure X, homozygous-good on **8/9** traits by ~cycle 15 (vs naive 4/9
plateau). The last trait is a **convergence TAIL** -- and it's a BREEDING-LOOP
DYNAMICS problem, not a scoring tweak. Characterized failure modes (all observed):

1. **Cargo saturation freezes the pool.** Each mating yields 1 princess but
   several drones, so cargo fills with drones. Once full, offspring princesses
   can't land -> the princess pool dwindles to ZERO -> `perfect_need_princess`
   -> the pool goes dead-flat for 1000+ cycles at ~stage 6-7 even though the
   world already holds the X-pure + working-trait carriers needed to finish.
2. **Naive pruning over-protects.** "Discard low-fit but never a working-trait
   carrier" backfires when the working trait is COMMON (the all-good donor
   spreads e.g. nocturnal widely) -- almost every bee is a carrier, nothing gets
   discarded, cargo stays full.
3. **Deterministic single-pair pick** -> all apiaries breed the identical mating
   each cycle (no exploration). Randomized top-K pairing ALONE (without fixing
   saturation) regressed to 7/9 -- noise without turnover.
4. **Scoring must stay fitness-dominant** (species only a tiebreak) or a good
   allele can never enter the X-pure line -- confirmed (an `xAlleles*100` species
   weight stalled/diverged; a first best-by-fitness cut diverged to -1).

What a full 9/9 fix needs (cohesive, not incremental patches): a bounded,
ROLE-BALANCED, EVOLVING pool -- e.g. keep a fixed small cargo pool (top ~6
princesses + ~8 drones by fitness, hard total cap) with only a FEW working-trait
carriers retained (not all), storage as overflow + restock so genes aren't lost,
and randomized top-K pairing. The princess/drone production imbalance is the core
tension to manage. This is a self-contained subsystem worth its own focused pass.

## Implementation plan (original / remaining)

- `bee_combine.lua` (pure): the serial-imprint planner. Given the current pool
  (genotypes), the target species, the coverable trait order, and `isGood`,
  return the next locus-set sub-goal + which pair to breed (or "sub-goal met" /
  "done"). Mirrors bee_breeding's role but with serial activation + allele-count
  fitness. Unit-test against crossRaw like the experiments.
- Perfect phase wiring: replace the naive species-mode dispatch with the combine
  planner per target species; maintain the max donor as a renewable bank; advance
  the per-species sub-goal (trait k) as each is fixed; species is "perfected" when
  a stored bee is X-pure + all-coverable-GG (already the completion check).
- Keep the donor bank stocked (donor×donor) so the good-allele source never runs
  out during a long per-species imprint.
```
