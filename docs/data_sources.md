# Bee data sources (mod source repos)

Where to source authoritative bee data (allele templates, breeding trees/mutations,
special conditions). These are the mod source repos on this machine; keep the paths
current if they move. **When in doubt about bee mechanics or data, read these — they
are ground truth, above any in-game dump.**

| Mod | Repo path (local) | Contains |
|---|---|---|
| **Forestry** | `C:/Users/Joseph Kan/Desktop/ForestryMC/src/main/java/forestry/apiculture/genetics/BeeDefinition.java` | Base + honey/noble/industrious/… branch species: default allele templates (`setAlleles`) **and** breeding trees (`registerMutations` → `registerMutation(a, b, chance)`). |
| **ExtraBees / Binnie** | `C:/Users/Joseph Kan/Desktop/Binnie/src/main/java/binnie/extrabees/genetics/ExtraBeeBranchDefinition.java` | Per-**branch** default templates (`setBranchProperties`). Species (`ExtraBeeDefinition.java`, alongside) inherit these + their own mutations. |
| **MagicBees** | `C:/Users/Joseph Kan/Desktop/MagicBees/src/main/java/magicbees/bees/BeeGenomeManager.java` | Per-species `getTemplateX()` methods (base `getTemplateModBase()` + overrides). Mutations are registered elsewhere in `magicbees/bees/`. |

Other useful files usually sit next to these: `*Definition.java` for species/mutations,
`Allele*.java` / `EnumAllele` for the enum→value scale, and each mod's mutation
registration for the **breeding trees**.

## The three template formats

- **Forestry** — enum constant `NAME(BeeBranchDefinition.X, …) { setAlleles(t){ AlleleHelper.instance.set(t, EnumBeeChromosome.TRAIT, EnumAllele.Cat.VALUE); } }`. Only non-default alleles are set; the rest come from the branch/base default.
- **ExtraBees** — same `AlleleHelper.instance.set(…)` form but in `setBranchProperties` on the **branch** enum, so it's a branch-level default shared by that branch's species.
- **MagicBees** — `genome[EnumBeeChromosome.TRAIT.ordinal()] = Allele.getBaseAllele("valueKey")`; each `getTemplateX()` starts from `getTemplateModBase()`.

## `bee_templates.dat` (parsed extract)

`scripts/parse_bee_templates.lua` parses all three into `bee_templates.dat`:

```lua
{ [name] = { kind="species"|"branch"|"template", source="forestry"|"extrabees"|"magicbees",
             traits = { speed="fast", fertility="high", lifespan="shortest", … } }, … }
```

Values are **normalized across mods** (Forestry `Speed.FAST` and MagicBees `speedFast`
both → `"fast"`; `BOTH_2` / `toleranceBoth1` → `"both2"` / `"both1"`; booleans → `"true"`).
200 entries, 143 with allele overrides. Re-run after a mod update:
`lua scripts/parse_bee_templates.lua` (edit the `SOURCES` paths at the top).

## TODOs

1. **Numeric mapping.** The template values are enum NAMES (`"fast"`, `"high"`,
   `"shortest"`). `bee_trait_config.isGoodValue` compares the game's raw genome
   values (speed≈0.6/1.2 floats, fertility 1–4 ints, tolerance strings like
   `"BOTH_5"`). Build an enum-name → raw-value map (from `EnumAllele` in the Forestry
   repo) so `bee_templates.dat` feeds `bee_traitmax_mutation.selectDonors` directly.
   Confirm the exact floats against a live `getQueen` dump.
2. **Validate breeding trees.** Cross-check the committed `bee_mutations.dat`
   (dumped from the live game) against the `registerMutation(a, b, chance)` calls in
   these repos — parents, chance, and special conditions — to catch any dump gaps or
   GTNH overrides. A `scripts/parse_bee_mutations.lua` (same style as the template
   parser) would make this a repeatable diff.
