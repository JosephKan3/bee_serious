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

## Implementation plan (next)

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
