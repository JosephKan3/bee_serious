--[[
  Local Sim Runner
  -----------------
  Runs the REAL bee_keeper_manager.lua/bee_keeper_nav.lua/bee_keeper_ui.lua
  -- completely unmodified -- against bee_keeper_sim.lua's fake world
  instead of real hardware. This is the "run it locally first" tool: same
  decision logic, same UI, real (if simplified) genetics, just no
  Minecraft required.

  Usage:
    lua bee_keeper_local_sim_run.lua [ui] [verbose] [paused] [cycles] [mode] [targetSpecies] [WxH]

  ui            show the live dashboard (same as the real run script's "ui")
  verbose       after every cycle, dump EVERYTHING in the simulated
                world: the agent's own status (position/facing/energy/
                selected slot), every occupied cargo slot, every occupied
                storage slot, and every apiary's queen/drone/output
                slots -- item, quantity, species, and a stable per-bee
                UID (see bee_keeper_sim.lua's toStack) so you can tell
                two genetically-identical drones apart, or track one
                specific individual across cycles. Works with or without
                "ui" (prints as plain text either way, so combining it
                with "ui" interleaves with the dashboard's redraws).
  paused        start paused instead of running immediately -- see
                PAUSE/STEP CONTROL below.
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

  PAUSE/STEP CONTROL:
    While running, create a file named bee_sim.pause in the current
    directory (e.g. `touch bee_sim.pause` from another window) to pause
    at the start of the next TASK (harvest/decide/walk/restock/etc --
    Status.onChange's granularity, not bee_keeper_nav.lua's per-block
    M.onStep) -- a walk already in progress always finishes first, so
    one step is always a complete action, e.g. "finish walking to the
    next apiary", never a partial one. Once paused, you'll get a prompt:
      (s)tep    -- perform exactly the next task, then pause again
      (r)esume  -- stop pausing, run freely (create bee_sim.pause again
                   to interrupt it later)
      (q)uit    -- exit immediately

  Examples:
    lua bee_keeper_local_sim_run.lua ui 30 mutation
    lua bee_keeper_local_sim_run.lua ui 30 species Sticky
    lua bee_keeper_local_sim_run.lua ui 30 traitmax 40x14
    lua bee_keeper_local_sim_run.lua verbose 10 traitmax
    lua bee_keeper_local_sim_run.lua ui paused 30 traitmax

  Bypasses bee_keeper_setup.lua's interactive area scan entirely -- there's
  no physical world to discover here, so this just declares a handful of
  identical-goal sites directly. Everything AFTER that point (M.runCycle
  and everything it calls) is the exact same code path production uses.
--]]

local args = { ... }
local uiEnabled = false
local verboseEnabled = false
local startPaused = false
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
  elseif a == "paused" then
    startPaused = true
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
config.trashPos = config.trashPos or { x = -8, z = -8 }
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

-- ============================================================
-- Pause/resume/step control -- hooked into Status.onChange (task-level:
-- harvest/decide/walk/restock/etc, one Status.setStep call each), NOT
-- Nav.onStep (per-block movement) -- so a walk already in progress
-- always finishes uninterrupted, and one "step" is always one whole
-- task, e.g. "finish walking to the next apiary", never a partial one.
--
-- Stock Lua has no non-blocking stdin, so a currently-RUNNING sim can't
-- be interrupted mid-flight by typed input alone -- PAUSE_SIGNAL_FILE
-- gives a way to request a pause from another window while it's running
-- (checked once per task, cheap). Once actually paused, io.read() blocks
-- normally for the step/resume/quit prompt.
-- ============================================================

local PAUSE_SIGNAL_FILE = "bee_sim.pause"
local controlMode = startPaused and "paused" or "running"

local function consumePauseSignal()
  local f = io.open(PAUSE_SIGNAL_FILE, "r")
  if not f then return false end
  f:close()
  os.remove(PAUSE_SIGNAL_FILE)
  return true
end

local function checkControl()
  if controlMode == "running" and consumePauseSignal() then
    controlMode = "paused"
  end
  if controlMode ~= "paused" then return end

  -- Restores normal terminal behavior (visible cursor, auto-wrap) around
  -- the prompt so typing is actually visible -- harmless no-op in non-ui
  -- mode, which never disabled them in the first place.
  Sim.endScreen()
  while true do
    io.write(string.format("\n[paused] next: %s -- (s)tep, (r)esume, (q)uit > ", Status.get().step))
    local cmd = io.read()
    cmd = (cmd or "q"):lower()
    if cmd == "" or cmd == "s" or cmd == "step" then
      break -- proceed with exactly this one task; stays paused for next time
    elseif cmd == "r" or cmd == "resume" then
      controlMode = "running"
      break
    elseif cmd == "q" or cmd == "quit" then
      print("Quitting.")
      os.exit(0)
    else
      print("Unknown command: " .. tostring(cmd))
    end
  end
  Sim.beginScreen() -- re-hide cursor / disable auto-wrap for the next redraw
end

if uiEnabled then
  local UI = require("bee_keeper_ui")
  local gpu = require("component").gpu
  local _termW, termH = Sim.resolveTermSize(gridWidth, gridHeight)
  local extras = { chargerPos = config.chargerPos, storagePos = config.storagePos, trashPos = config.trashPos }

  local function draw()
    UI.draw(config.sites, Nav.getPos(), extras, Status.get(), Sim.world.drone.energy,
      M.listCargo(config), listSimStorage())
    -- Built into the SAME redraw as the dashboard above, right below its
    -- last row -- not separate scrolling print() text, which would
    -- corrupt the dashboard's fixed-position writes. Updates on every
    -- refresh (every Status.onChange AND every Nav.onStep block-move),
    -- same cadence as the dashboard itself, not just once per cycle.
    if verboseEnabled then
      local row = termH + 2
      -- segments is an array of { text=, color= } (not a plain string)
      -- -- lets each piece (allele letters, princess/drone item names)
      -- get its own gpu.setForeground() color instead of one flat color
      -- per line.
      Sim.dumpWorld(function(segments)
        local col = 1
        for _, seg in ipairs(segments) do
          gpu.setForeground(seg.color)
          gpu.set(col, row, seg.text)
          col = col + #seg.text
        end
        row = row + 1
      end, config.sites)
    end
  end
  Status.onChange = function()
    -- Once per NEW task -- see Sim.tickStep's header notes -- keeps the
    -- verbose dump's cyan "drone just moved" flash held steady for this
    -- task's entire duration instead of it decaying after one redraw.
    Sim.tickStep()
    draw()
    Sim.realSleep(Sim.secondsPerAction)
    checkControl()
  end
  -- Fires once per individual block moved (see bee_keeper_nav.lua's
  -- M.onStep), not just once per whole gotoXZ call -- without this,
  -- movement would jump straight to the destination instead of actually
  -- rendering block-by-block. Paced separately (much faster) -- a
  -- multi-block walk at the full per-action pace would take forever to
  -- watch. Deliberately does NOT call checkControl -- a walk in progress
  -- always finishes uninterrupted; pausing only ever happens between
  -- whole tasks (see checkControl's header notes).
  Nav.onStep = function()
    draw()
    Sim.realSleep(Sim.secondsPerStep)
  end
else
  Status.onChange = function()
    Sim.tickStep()
    print("  [" .. Status.get().step .. "]")
    Sim.realSleep(Sim.secondsPerAction)
    checkControl()
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
    -- In ui mode, verbose is already part of every redraw (see draw()
    -- above) -- printing it again here too would just scroll separately
    -- underneath the dashboard.
    if verboseEnabled then
      print(string.format("  [verbose] after cycle %d:", cycle))
      Sim.dumpWorld(nil, config.sites)
    end
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
