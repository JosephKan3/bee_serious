# GTNH / Forestry bee genetics — reference

Summarized from the **GTNH wiki "Bee Breeding Guide"**
(https://wiki.gtnewhorizons.com/wiki/Bee_Breeding_Guide — the live page is behind a
Miraheze anti-bot wall; fetch the wikitext with `?action=raw`) and confirmed against live
`getQueen()` dumps (see `docs/oc_forestry_api.md`, `scripts/probe_dominance.lua`). This is
the mental model the genebank / breeding logic is built on — keep it in sync if the mod
changes.

## Lifecycle

- A **princess** + a **drone** combine into a **queen**. The queen works in the housing
  for some bee ticks, then dies and produces offspring.
- **The queen's own traits are exactly the princess's** (the drone's traits do *not*
  affect the queen — only the offspring).
- On death the queen produces **0–1 princesses and 1–4 drones**. The drone count equals
  the queen's **fertility** (1–4).
- **Pristine** queens **always** produce a (1) princess. **Ignoble** queens can fail to
  produce a princess once their **generation > 100** (+2% chance of "no princess" per
  generation over 100) — i.e. ignoble lines eventually die out. → **use pristine only.**

## Genome

- Each **trait** has two alleles: a **primary** and a **secondary** slot. In the OC API
  these are `active` and `inactive`.
- **`active` = the DOMINANT / expressed allele; `inactive` = the recessive one.** The mod
  resolves dominance for us — a hybrid *behaves as* its dominant allele. (Confirmed on a
  live hybrid: `active.species=Eldritch`, `inactive.species=Tolerant`, displays as
  Eldritch.) If both alleles have the *same* dominance, the primary slot is used.
- A trait is **homozygous / "purebred"** if both slots are equal, else **heterozygous /
  "hybrid"**. **Species is just another trait** — a bee is "purebred X" iff
  `active.species == inactive.species == X`.
- A bee's **expressed species** (what it "is", its `displayName`/`ident`) = `active.species`.
- **`isNatural`** = **pristine (true) / ignoble (false)**. `isSecret` is unrelated (a
  research flag).

## Inheritance

- Each offspring gets **two alleles per trait — one drawn at random from each parent** (a
  parent contributes one of *its* two alleles), assigned to the primary/secondary slots in
  **random order**. Expression of the result then follows dominance (above).
- An identical princess/drone pair → identical offspring. Any heterozygosity → offspring
  that are assorted mixes.
- **Purebred × purebred of the SAME species → purebred offspring, every time.** (This is
  why a purebred "bank" bred against itself never drifts.)

## Mutation

- When forming each offspring, for **each parent**: 50% chance to check a mutation between
  *that parent's PRIMARY species* and *the other parent's SECONDARY species*, and 50% for
  *its secondary* × *the other's primary*.
  - So a mutation is only ever checked between **one primary and one secondary** — never
    primary×primary or secondary×secondary. For **purebred** parents (primary==secondary)
    this is moot; it matters only with hybrids.
- On a successful roll the parent is **replaced with the DEFAULT (purebred) bee of the
  mutated species** → **mutation results are PUREBRED**. Non-mutated offspring are hybrids
  of the two parents.
- **Direction:** the species *pair* is commutative for the *chance* (Forest+Meadows ==
  Meadows+Forest). Our `bee_mutations.dat` still records an ordered `allele1`(princess)/
  `allele2`(drone) pair; we load in that order as a safe default.
- Mutation **chance** is boosted by frames (soul/metabolic; the Frame of Frenzy = 10×;
  Oblivion) and lowered by conditions not being met. At/near **100% mutation chance**,
  breeding two purebred parents that have a mutation yields a purebred mutated bee *every
  time* — no stat-fiddling needed.
- Special **conditions** (foundation block, biome tag, dimension, climate, time) gate some
  mutations — these are the strings the robot beeps-and-awaits on.

## Breeding strategy (the loop the genebank implements)

From the guide, and the basis of the v0.3 genebank design:

1. Acquire **pristine** princesses of base species by scooping wild hives (~70% of hive
   princesses are ignoble — discard those). Keep a stock.
2. For each species, hold a **purebred bank**: a purebred princess + a small stack of
   purebred drones, sustained by breeding it **against itself** (stays purebred).
3. To reach a new species, breed a purebred princess of one parent species with a purebred
   drone of the other. **Keep the purebred mutation results; junk the hybrids** (throw them
   in a junk chest — do *not* try to re-purify a hybrid; that's the mistake that causes
   species drift).
4. Purify/convert **by genotype**, not by displayed species: breed the line against pure
   drones of the target until *both* alleles read the target (homozygous). A hybrid may
   *display* the other (dominant) species while it still carries the target allele — track
   the target explicitly.
5. Advance down the mutation tree, keeping a stock of each intermediate you may still need.

## Implications for this project

- **Bank = purebred princess + N purebred drones per species, bred pure×pure; never
  spent/converted.** Working princesses for mutations come from **pristine breeder
  princesses converted against bank drones**, not from the bank's own princess.
- **Junk hybrids**; never re-purify them.
- **Judge purity/conversion by genotype** (`active.species == inactive.species`), never by
  the displayed (dominant) species alone.
- **Pristine only** (`isNatural`); ignoble lines degrade past generation 100.
- Sustain math: a pristine purebred queen always returns 1 princess + `fertility` drones,
  so a bank sustains its 1 princess and accumulates drones on its own.
