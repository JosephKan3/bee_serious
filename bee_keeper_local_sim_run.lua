--[[
  Local Sim Runner
  -----------------
  Runs the REAL bee_keeper_manager.lua/bee_keeper_nav.lua/bee_keeper_ui.lua
  -- completely unmodified -- against bee_keeper_sim.lua's fake world
  instead of real hardware. This is the "run it locally first" tool: same
  decision logic, same UI, real (if simplified) genetics, just no
  Minecraft required.

  Usage:
    lua bee_keeper_local_sim_run.lua [ui] [verbose] [cycles] [mode] [targetSpecies] [WxH]

  ui            show the live dashboard (same as the real run script's "ui")
  verbose       after every cycle, dump every occupied cargo AND storage
                slot -- item, quantity, species, and a stable per-bee UID
                (see bee_keeper_sim.lua's toStack) so you can tell two
                genetically-identical drones apart, or track one
                specific individual across cycles. Works with or without
                "ui" (prints as plain text either way, so combining it
                with "ui" interleaves with the dashboard's redraws).
  cycles        how many cycles to run before stopping (default 20)
  mode          traitmax (default), species, or mutation -- ALL simulated
                apiaries share this one goal; the drone treats them as
                spare capacity for the same objective, not separate jobs
  targetSpecies only meaningful for species/mutation modes (defaults to
                "Sticky" for species, "NewBee" for mutation -- matching
                bee_keeper_sim.lua's built-in demo data)
  WxH           dashboard grid size, e.g. "40x14" (only meaningful with
                "ui"). Without this, the grid auto-fits your real
                terminal; give this to force something smaller (or
                larger) instead. Floor is 24x7 -- bee_keeper_ui.lua's
                layout stops making sense below that.

  Examples:
    lua bee_keeper_local_sim_run.lua ui 30 mutation
    lua bee_keeper_local_sim_run.lua ui 30 species Sticky
    lua bee_keeper_local_sim_run.lua ui 30 traitmax 40x14
    lua bee_keeper_local_sim_run.lua verbose 10 traitmax

  Bypasses bee_keeper_setup.lua's interactive area scan entirely -- there's
  no physical world to discover here, so this just declares a handful of
  identical-goal sites directly. Everything AFTER that point (M.runCycle
  and everything it calls) is the exact same code path production uses.
--]]

local args = { ... }
local uiEnabled = false
local verboseEnabled = false
local cycles = 20
local mode = "traitmax"
local targetSpecies = nil
local gridWidth, gridHeight = nil, nil
local MODES = { traitmax = true, species = true, mutation = true }

for _, a in ipairs(args) do
  local w, h = a:match("^(%d+)x(%d+)$")
  if a == "ui" then
    uiEnabled = true
  elseif a == "verbose" then
    verboseEnabled = true
  elseif w then
    gridWidth, gridHeight = tonumber(w), tonumber(h)
  elseif MODES[a] then
    mode = a
  elseif tonumber(a) then
    cycles = tonumber(a)
  else
    targetSpecies = a
  end
end

if mode == "species" then
  targetSpecies = targetSpecies or "Sticky"
elseif mode == "mutation" then
  targetSpecies = targetSpecies or "NewBee"
end

local Sim = require("bee_keeper_sim")

local config = require("bee_keeper_manager_config")

-- All apiaries share the SAME goal (per your call) -- the drone treats
-- them as spare capacity for one objective, not N separate jobs.
local SITE_COUNT = 3
local sitePositions = {
  { x = 4, z = 3 }, { x = -3, z = 6 }, { x = 8, z = -5 },
}
config.sites = {}
for i = 1, SITE_COUNT do
  table.insert(config.sites, {
    name = "apiary" .. i,
    x = sitePositions[i].x,
    z = sitePositions[i].z,
    mode = mode,
    targetSpecies = targetSpecies,
  })
end

config.storagePos = config.storagePos or { x = -6, z = -6 }
config.chargerPos = config.chargerPos or { x = 0, z = 0 }
-- Real hardware auto-derives this from getInventorySize() (see
-- M.resolveWorkingSlots), but that needs component.inventory_controller
-- mocked, which only happens AFTER Sim.install below -- and Sim.install
-- itself needs config.workingSlots already set to seed demo cargo. No
-- real inventory to query here anyway, so just keep a fixed demo list.
config.workingSlots = config.workingSlots or { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }

-- Must install the fakes BEFORE anything requires component/sides/computer
-- for the first time (require caches on first load).
Sim.install(config, config.sites, { uiWidth = gridWidth, uiHeight = gridHeight })

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
local Status = require("bee_keeper_status")

Nav.setHome(70)

-- Storage in the same { {slot, stack}, ... } shape M.listCargo uses, read
-- straight out of the fake world. This is a sim-only convenience -- real
-- hardware can't know a storage chest's contents without physically being
-- there (see bee_keeper_manager_run.lua's note on this), but the local
-- sim has full visibility into its own fake world, so showing it live is
-- reasonable for a debugging tool.
local function listSimStorage()
  local list = {}
  for slot, stack in pairs(Sim.world.storage) do
    table.insert(list, { slot = slot, stack = stack })
  end
  table.sort(list, function(a, b) return a.slot < b.slot end)
  return list
end

-- One line per occupied slot: item, quantity, species (for bees), and
-- the stable per-individual UID bee_keeper_sim.lua's toStack assigns --
-- lets you tell two genetically-identical drones apart, or track one
-- specific individual (e.g. a princess) across cycles as she moves
-- between cargo and an apiary.
local function formatStackVerbose(stack)
  if stack.individual then
    local species = stack.individual.active and stack.individual.active.species
    local Cfg = require("bee_trait_config")
    local speciesName = species and Cfg.speciesKey(species) or "?"
    return string.format("%s x%s (%s)%s", stack.name, tostring(stack.size or 1), speciesName,
      stack._uid and (" [uid=" .. stack._uid .. "]") or "")
  end
  return string.format("%s x%s", stack.name, tostring(stack.size or 1))
end

local function dumpVerbose()
  print("  --- cargo ---")
  local cargo = M.listCargo(config)
  if #cargo == 0 then print("    (empty)") end
  for _, entry in ipairs(cargo) do
    print(string.format("    slot %d: %s", entry.slot, formatStackVerbose(entry.stack)))
  end
  print("  --- storage ---")
  local storage = listSimStorage()
  if #storage == 0 then print("    (empty)") end
  for _, entry in ipairs(storage) do
    print(string.format("    slot %d: %s", entry.slot, formatStackVerbose(entry.stack)))
  end
end

if uiEnabled then
  local UI = require("bee_keeper_ui")
  local extras = { chargerPos = config.chargerPos, storagePos = config.storagePos, trashPos = config.trashPos }
  local function draw()
    UI.draw(config.sites, Nav.getPos(), extras, Status.get(), Sim.world.drone.energy,
      M.listCargo(config), listSimStorage())
  end
  Status.onChange = function()
    draw()
    Sim.realSleep(Sim.secondsPerAction)
  end
  -- Fires once per individual block moved (see bee_keeper_nav.lua's
  -- M.onStep), not just once per whole gotoXZ call -- without this,
  -- movement would jump straight to the destination instead of actually
  -- rendering block-by-block. Paced separately (much faster) -- a
  -- multi-block walk at the full per-action pace would take forever to
  -- watch.
  Nav.onStep = function()
    draw()
    Sim.realSleep(Sim.secondsPerStep)
  end
else
  Status.onChange = function()
    print("  [" .. Status.get().step .. "]")
    Sim.realSleep(Sim.secondsPerAction)
  end
end

print(string.format("Running %d cycle(s) against the local simulator -- mode=%s%s%s...\n",
  cycles, mode, targetSpecies and (" target=" .. targetSpecies) or "", uiEnabled and " (ui)" or ""))

for cycle = 1, cycles do
  if not uiEnabled then
    print(string.format("== cycle %d ==", cycle))
  end
  local log = M.runCycle(config)
  if not uiEnabled then
    for _, line in ipairs(log) do
      print(line)
    end
  end
  if verboseEnabled then
    print(string.format("  [verbose] after cycle %d:", cycle))
    dumpVerbose()
  end
end

if uiEnabled then
  -- Leave the final frame up rather than clearing, but put the terminal's
  -- auto-wrap and cursor back (see Sim.beginScreen/endScreen).
  Sim.endScreen()
else
  print("")
  print(string.format("Done -- %d cycles.", cycles))
  print(string.format("Drone ended at (%d,%d).", Nav.getPos().x, Nav.getPos().z))
end
