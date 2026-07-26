# Robot environment (real hardware)

## OC filesystem home (host-mirrored, readable straight off disk)

The running robot's OpenComputers home directory — its live code, data files, and
`bee_keeper.log` — is on disk at:

```
C:\Users\Joseph Kan\AppData\Roaming\PrismLauncher\instances\GT_New_Horizons_2.8.4_Java_17-25\.minecraft\saves\minecraft_slice\opencomputers\b92dcee9-d7db-4d6f-9529-6a449bef81cc\home
```

Read `bee_keeper.log` there to see what the live robot is doing (it's the same file
the runner appends every `print()` to). `version.lua` there is the DEPLOYED program
version (may lag the repo until the user runs `updater` + reboots).

- GTNH pack: **2.8.4**, Java 17-25, PrismLauncher instance `GT_New_Horizons_2.8.4_Java_17-25`.
- World save: `minecraft_slice`. Robot UUID: `b92dcee9-d7db-4d6f-9529-6a449bef81cc`.
- Setup: **2 apiaries, 5 bee-storage blocks, 1 honey drawer, 1 trash**, all traitmax
  mode by default (per the scan saved in `bee_keeper_sites.dat`).

## Logging caveat (important)

`bee_keeper_manager_run.lua` tees every `print()` to `bee_keeper.log`, BUT the
per-cycle status lines returned by `M.runCycle` are only printed when the `ui`
dashboard is OFF. Running `bee_keeper_manager_run ui` (the usual way) therefore
leaves the log with only startup + stray diag prints — none of the scheduler's
per-cycle decisions. Fixed so cycle status is logged regardless of UI mode.
