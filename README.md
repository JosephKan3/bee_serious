# bee_serious

Automated Forestry bee breeding for OpenComputers (GTNH 2.8.4). A Robot with
the Beekeeper + Inventory Controller upgrades flies between apiaries, reads
each bee's genome, picks the best breeding pair via a Punnett-square
selection algorithm, and swaps them in — no transposer network required.

## Requirements

- A **Robot** (not a Drone) with:
  - **Beekeeper Upgrade** installed
  - **Inventory Controller Upgrade** installed
  - A **Geolyzer** (used once, during area setup, to identify apiary/storage
    blocks)
  - An **Internet Card** (optional — only needed for the auto-updater; the
    manager runs fine without one)
- Honey or honeydew stocked in the robot's inventory (see `honeySlot` in the
  config) — consumed by `beekeeper.analyze()`.
- The robot positioned at the Y level you want it to operate at before first
  run. It never changes altitude on its own.

## Install

On the robot's OpenOS shell:

```
wget https://raw.githubusercontent.com/JosephKan3/bee_serious/main/installer.lua && installer
```

This downloads every file the robot needs into its home directory. Re-running
the installer later (e.g. after a manual redeploy) will **not** overwrite
`bee_keeper_manager_config.lua` or `bee_keeper_sites.dat` if they already
exist — those are your data, not shipped defaults.

## First run

```
bee_keeper_manager_run
```

Add `ui` to show a live dashboard (site layout, current position, current
step) instead of a scrolling log:

```
bee_keeper_manager_run ui
```

On first run (no `bee_keeper_sites.dat` yet) you'll be walked through an
interactive area scan:

1. Enter the scan width (X) and depth (Z), in blocks, relative to the
   robot's current position as `(0,0)`. Leave blank to skip setup entirely.
2. An ASCII preview of the planned area prints.
3. The robot walks the 4 corners of that area (beeping at each, since a
   Robot has no drone light) so you can visually confirm the boundary
   in-game before committing.
4. Confirm the boundary looks right (`Y`/`n`).
5. The robot sweeps the whole area in a zigzag pattern, identifying apiary
   and storage blocks via the Geolyzer, and saves the result to
   `bee_keeper_sites.dat`.

Every discovered site defaults to **traitmax** mode. To assign a species or
mutation target to a specific site, edit `bee_keeper_manager_config.lua`'s
`siteOverrides`, keyed by the site name the scan assigned (`site1`,
`site2`, ...):

```lua
siteOverrides = {
  ["site1"] = { mode = "species", targetSpecies = "Sticky" },
  ["site2"] = { mode = "mutation", targetSpecies = "SomeNewSpecies" },
},
```

On later runs, if `bee_keeper_sites.dat` already exists you'll be asked to
press Enter to keep it, or type `rescan` to redo the area scan.

## Config reference (`bee_keeper_manager_config.lua`)

| Field | Meaning |
|---|---|
| `honeySlot` | Slot holding honey/honeydew stock. Restock manually. |
| `workingSlots` | Slots used as the live candidate-bee pool. Exclude `honeySlot`. |
| `productSlots` | Slot numbers on an apiary where offspring/product output lands. **Verify against your real apiary** — see Troubleshooting. |
| `minCopies` | How many independent drone-sources of a good allele to keep on hand per trait. |
| `onDiscard` | Optional `function(bee)` for drones the algorithm doesn't want. Defaults to flying them to `storagePos` and dropping them. |
| `storageSlotCount` | How many slots to try in the storage container before giving up on a discard. |
| `apiaryBlockNames` / `storageBlockNames` | Block names (`geolyzer.analyze(down).name`) the area scan matches against. See Troubleshooting for how to verify these. |
| `showBorderPreview` | Whether setup walks the 4 corners before scanning. |
| `needCharge` / `chargeThreshold` / `chargerPos` | Auto-return-to-charge behavior. |
| `mutationFallback` | Optional static mutation-recipe table, used only if the live `bee_housing` lookup isn't reachable. |
| `siteOverrides` | Per-site mode/target assignment (see above). |
| `storagePos`, `sites` | Filled in automatically from the area scan — leave `nil`. |

## Breeding modes

- **traitmax** (default) — no species target, just get as close to
  max-trait as possible from whatever's on hand.
- **species** — you already hold at least one specimen of `targetSpecies`;
  purify toward pure-species + max traits simultaneously.
- **mutation** — you don't yet hold `targetSpecies`; looks up its mutation
  recipe, loads the best satisfiable parent pair, and keeps re-attempting
  (mutation is probabilistic per mating in Forestry). Once a specimen of
  `targetSpecies` shows up in the harvest, switch the site to `species`
  mode to take over from there.

## Updating

```
updater
```

Compares your local `version.lua` against the repo's and prompts before
downloading anything. Never touches `bee_keeper_manager_config.lua` or
`bee_keeper_sites.dat`. Runs silently and automatically at the start of
every `bee_keeper_manager_run` (no-op without an internet card).

## Troubleshooting

Every `print()` (from any file) is also appended to `bee_keeper.log` in the
robot's home directory, and any uncaught error is caught and logged with a
full traceback instead of just vanishing off-screen. Since this file lives
in OpenComputers' host-mirrored filesystem
(`saves/<world>/opencomputers/<uuid>/home/` on disk), it's directly
readable outside Minecraft.

Two block/slot layouts are **not safe to assume** and should be verified
against your real hardware before relying on them:

- **Block names** — `apiaryBlockNames` / `storageBlockNames` are matched
  exactly against `geolyzer.analyze(down).name`. If the area scan isn't
  finding your apiaries or storage container, hover the robot directly over
  a known one and run:

  ```
  require("bee_keeper_setup").probeBlockBelow()
  ```

  This prints the real block name — add it to the appropriate list in the
  config.

- **Product slot numbers** — `productSlots` (default `{7..15}`) is not
  guaranteed to match every apiary tier/type. If harvesting silently pulls
  nothing despite visible product waiting, hover directly over that apiary
  and run:

  ```
  require("bee_keeper_setup").probeInventoryBelow()
  ```

  This dumps every slot's contents (also written to `inventory_probe.log`)
  so you can see exactly which slot numbers the princess/drones/combs
  actually occupy, and adjust `productSlots` accordingly.

## Running locally without Minecraft

A full local simulator is included for testing without real hardware:

```
lua bee_keeper_local_sim_run.lua ui 30 traitmax
```

See that file's header comment for the full argument list (cycles, mode,
target species, dashboard size). `*_test.lua` files are unit tests, run the
same way (`lua bee_keeper_manager_test.lua`, etc.).
