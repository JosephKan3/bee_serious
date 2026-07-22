# OpenComputers Forestry API — real GTNH reference

Source of truth for the OC ↔ Forestry bee API in **GTNH 2.8.4**, derived from the OC
integration source (`DriverBeeHouse.java`, `ConverterIAlleles.java`,
`ConverterIIndividual.java`, `UpgradeBeekeeper.scala`) **and confirmed against a live
dump** on real hardware. Keep this in sync when re-dumping.

---

## Component naming reality (IMPORTANT)

The apiary/alveary is **not** exposed as `bee_housing` in this build. A live
`component.list()` on a stationary computer with an OC **Adapter** next to a Forestry
apiary shows:

```
295145e2-...  tile_for_apiculture_0_name
```

i.e. the component **type is `tile_for_apiculture_0_name`** (derived from the block's
unlocalized name `tile.for.apiculture.0.name`), NOT `bee_housing`. But it exposes the
**exact same methods** as `DriverBeeHouse` (`getBeeBreedingData`, `listAllSpecies`,
`getBeeParents`, `getQueen`, `getDrone`, `canBreed`) — the driver is just registered
under the tile name here. Access it via `component.list("tile_for_apiculture_0_name")()`
or its address; do NOT rely on `component.bee_housing`.

The robot does NOT have this component (confirmed) — only the stationary
Adapter-next-to-apiary does. That's why the mutation graph is dumped ONCE on a
stationary setup and shipped to the robot as a static file, never queried live by the
robot.

Robot's own components (for reference): `beekeeper`, `inventory_controller`, `robot`,
`computer`, plus movement/inventory upgrades. No mutation component.

---

## `tile_for_apiculture_0_name` (a.k.a. `bee_housing`) — mutation + housing API

### `getBeeBreedingData()` → the ENTIRE mutation graph (this is what we dump)
Returns a 1-indexed array of maps. `allele1`/`allele2`/`result` are **plain species
localized-name strings**; `specialConditions` is an array of human-readable strings
(empty `{}` when none). Real samples:

```lua
{ specialConditions={}, result="Desolate", allele2="Barren", allele1="Arid", chance=10.0 }
{ specialConditions={"Occurs within a plains biome."}, result="Beefy", allele2="Skulking", allele1="Common", chance=12.0 }
{ specialConditions={"Requires Fire Crystal Cluster as a foundation."}, result="Ignis", allele2="Firey", allele1="Firey", chance=8.0 }
{ specialConditions={"Requires Entropy Crystal Cluster as a foundation."}, result="Essentia", allele2="Chaotic", allele1="Ordered", chance=8.0 }
```

`allele1`=`getAllele0()`, `allele2`=`getAllele1()` (ordered pair). **Direction:** the
user reports princess/drone direction matters for *triggering* a mutation (not for
normal inheritance). Vanilla Forestry checks both orders; whether GTNH enforces one, and
if so which of allele1/allele2 is the princess side, is still to be verified with one
real test-breed. Safe default: allele1 = princess, allele2 = drone.

### `getBeeBreedingData()` — live dataset stats (GTNH 2.8.4, 2024 dump)
- **538 mutations**, **430 distinct species**.
- **412 species are a mutation result** (reachable by breeding).
- **18 leaf species** (appear only as parents, never as a result) = the base stock you
  must obtain by other means (scoop/analyze wild bees). Everything else is breedable.
- **254 / 538 mutations carry special conditions** (230 distinct strings), categorized:
  - **Foundation block** — "Requires Block of Zinc as a foundation.", "Requires Fire
    Crystal Cluster as a foundation." (place a block under the apiary).
  - **Temperature / humidity** — "Requires Icy temperature.", "Requires Arid humidity.",
    "Requires temperature between Hot and Hellish." (apiary must be in a matching
    biome climate, or use climate frames).
  - **Biome** — "Occurs within a nether biome.", "Occurs within a plains biome.",
    "Required Biome Magical Forest".
  - **Dimension** — "Required Dimension Moon", "Required Dimension Venus",
    "Required Dimension End" (GTNH space dims — the whole apiary setup must be there).
  - **Time** — "During the night.", "During the New Moon.", "Occurs between December 21
    and December 27." (temporal window).
  These are exactly the strings the beep-and-await gate surfaces to the user.

### `listAllSpecies()` → array of species tables
```lua
{ uid="gregtech.bee.speciesAsh", name="Ash", humidity="Arid", temperature="Hot" }
{ uid="extrabees.species.blooming", name="Blooming", humidity="Normal", temperature="Normal" }
{ uid="forestry.speciesBoggy", name="Boggy", humidity="Damp", temperature="Normal" }
```
`name` is the display name used throughout `getBeeBreedingData` (allele1/allele2/result).
`uid` is namespaced (`gregtech.bee.species*`, `extrabees.species.*`, `forestry.species*`).
`humidity`/`temperature` are display strings ("Normal"/"Arid"/"Hot"/"Damp"/...).

### `getBeeParents(childNameOrUID)` → recipes producing that child
Set of `IMutation`, each converted by `ConverterIAlleles` — here allele1/allele2 are
**nested species tables** (unlike getBeeBreedingData's strings), and there is **no
`result`** field. Matched case-insensitively against species name OR uid.
```lua
{ allele1={ name="Forest", uid="forestry.speciesForest", humidity="Normal", temperature="Normal" },
  allele2={ name="Meadows", uid="...", humidity="...", temperature="..." },
  chance=15.0, specialConditions={ ... } }
```

### `getQueen()` / `getDrone()` → the housing's current bee (or nil if empty)
Returns an `IIndividual` directly (not wrapped in a stack). **nil when the apiary slot is
empty** (confirmed — an empty apiary returns nil). With an analyzed queen present, the
genome shape (via `ConverterIIndividual`) is:
```lua
{ type="bee", displayName=, ident="<species uid>", isAnalyzed=true, isSecret=false,
  canSpawn=, generation=, hasEffect=, isAlive=, isNatural=, health=, maxHealth=,
  active = {
    species = { name=, uid=, humidity=, temperature= },     -- nested table
    speed=<float>, lifespan=<int>, fertility=<int>,
    temperatureTolerance="BOTH_5", humidityTolerance="NONE", -- tolerance strings
    nocturnal=<bool>, tolerantFlyer=<bool>, caveDwelling=<bool>,
    flowerProvider="flowersRocks", flowering=<int>,
    effect="<unlocalized name>", territory=<area value> },
  inactive = { ...same keys... } }
```
**Matches `bee_trait_config.lua`'s `normalizeGenotype` exactly.** (Live genome sample
still TODO — needs an analyzed queen in the apiary during the dump; the first dump had an
empty apiary so `getQueen()`/`getDrone()` returned nil.)

### `canBreed()` → boolean.

---

## `beekeeper` (robot upgrade — already used; NO mutation data)
`swapQueen(side)`, `swapDrone(side)`, `getBeeProgress(side)`, `canWork(side)`,
`analyze(honeySlot)` (honey must be item `honeydew` or `honeyDrop`),
`addIndustrialUpgrade`/`getIndustrialUpgrade`/`removeIndustrialUpgrade`.

## Robot inventory reads (already used)
`inventory_controller.getStackInSlot(side,slot)` / `getStackInInternalSlot(slot)` →
`{ name, label, size, individual = { active=..., inactive=..., isAnalyzed=... } }`; the
`individual` sub-table matches the `getQueen`/`getDrone` genome shape above.

---

## Re-dump procedure (stationary computer + Adapter next to an apiary)
1. `local c=require("component"); local ser=require("serialization"); local d=c.tile_for_apiculture_0_name.getBeeBreedingData(); local f=io.open("bee_mutations.dat","w"); f:write(ser.serialize(d)); f:close(); print(#d.." mutations")`
2. `... c.tile_for_apiculture_0_name.listAllSpecies() ...` → `species.dat`
3. With an analyzed queen in the apiary: `... c.tile_for_apiculture_0_name.getQueen() ...` → `queen_genome.dat` (for the traitmax species→template map).

`serialization.serialize()` output is valid Lua — load it with `load("return "..s)()`.
