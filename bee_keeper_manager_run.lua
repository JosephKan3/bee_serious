--[[
  Entry point: runs area setup (if needed, or on request), loads the
  config, merges in the discovered sites, and runs bee_keeper_manager
  forever. Run this ON the drone with the beekeeper + inventory_controller
  upgrades installed, hovering at the Y level you want it to operate at.

  Pass "ui" as an argument to show a live dashboard (computed site layout,
  current drone position, and the current step) instead of the plain
  scrolling log -- e.g.:

    bee_keeper_manager_run ui

  Useful for debugging on the real Minecraft instance: you can watch what
  the drone thinks the world looks like and what it's doing right now,
  side by side with what it's actually doing in-game.

  LOGGING: every print() (from this file or anything it requires) is also
  appended to bee_keeper.log in the current directory, and any uncaught
  error is caught and logged with a full traceback before the script
  exits, instead of just vanishing off the in-game screen. Since this
  file lives in OpenComputers' host-mirrored filesystem
  (saves/<world>/opencomputers/<uuid>/home/ on disk), that log is
  directly readable from outside Minecraft -- paste the path and it can
  be read straight off disk without needing terminal output relayed by
  hand.
--]]

local LOG_PATH = "bee_keeper.log"

local logFile = io.open(LOG_PATH, "a")
if logFile then
  logFile:write(string.format("\n===== run started %s =====\n",
    os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(os.time())))
  logFile:flush()

  -- Global override so EVERY print() anywhere (this file, bee_keeper_setup,
  -- bee_keeper_manager, etc.) gets logged too, not just the ones written
  -- with logging in mind -- avoids having to hunt down and rewrite every
  -- print() call site across the whole codebase.
  local realPrint = print
  _G.print = function(...)
    realPrint(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    logFile:write(table.concat(parts, "\t") .. "\n")
    logFile:flush()
  end

  -- bee_keeper_setup.lua's prompts (promptNumber/promptYesNo) write via
  -- io.write, not print (no trailing newline, since the cursor needs to
  -- stay on the same line for input) -- without this, a crash or hang
  -- during/right after a prompt would leave the log showing nothing at
  -- all past "run started", indistinguishable from "still waiting on
  -- input" vs "actually crashed". Tee'd the same way, one log line per
  -- write call so it stays readable even without the missing newline.
  local realWrite = io.write
  io.write = function(...)
    realWrite(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    logFile:write(table.concat(parts, "") .. "\n")
    logFile:flush()
  end
end

-- Captured at chunk scope -- `...` (the args OpenOS passes this script)
-- isn't reachable from inside the nested main() function below.
local scriptArgs = { ... }

local function main(args)
  -- Auto-update check (silent -- only interrupts if an update is actually
  -- available; harmless no-op without an internet card). Same pattern as
  -- Level-Maintainer's Maintainer.lua.
  pcall(function()
    local shell = require("shell")
    shell.execute("updater silent")
  end)

  local M = require("bee_keeper_manager")
  local Setup = require("bee_keeper_setup")
  local Nav = require("bee_keeper_nav")
  local Status = require("bee_keeper_status")
  local config = require("bee_keeper_manager_config")

  local uiEnabled = false
  local stepEnabled = false
  local traceDir = nil
  for i, a in ipairs(args) do
    if a == "ui" then uiEnabled = true end
    if a == "step" then stepEnabled = true end
    -- `trace <dir>`: export a per-step state trace the local simulator can
    -- replay to import inheritance + validate every other action. Takes the
    -- PARENT DIRECTORY (e.g. the robot's home dir), not a full file path --
    -- bee_trace drops bee_trace.dat inside it.
    if a == "trace" then traceDir = args[i + 1] or "." end
  end

  -- STEP MODE (bee_keeper_manager_run step): pause before every TASK so real
  -- hardware can be single-stepped in lockstep with the local simulator, to
  -- validate the sim matches Minecraft action-for-action. The hook is on
  -- Status.onChange -- a whole task boundary ("walk to apiary2", "harvest",
  -- "load drone") -- NOT bee_keeper_nav's per-block Nav.onStep, so a multi-block
  -- flight advances to its destination in ONE step (no prompt per block moved),
  -- exactly as requested. Starts paused; (s)tep does one task, (r)esume runs
  -- free, (q)uit exits. Reads from the OC terminal via io.read (OpenOS).
  local stepControl = stepEnabled and "paused" or "running"
  local function checkStep()
    if not stepEnabled or stepControl ~= "paused" then return end
    while true do
      io.write(string.format("\n[step] next: %s -- (s)tep, (r)esume, (q)uit > ", Status.get().step))
      local cmd = (io.read() or "q"):lower()
      if cmd == "" or cmd == "s" or cmd == "step" then
        break
      elseif cmd == "r" or cmd == "resume" then
        stepControl = "running"; break
      elseif cmd == "q" or cmd == "quit" then
        print("Quitting."); os.exit(0)
      else
        print("Unknown command: " .. tostring(cmd))
      end
    end
  end

  Nav.setHome(nil) -- locks flight altitude to wherever the drone currently is

  local saved = Setup.run(config)
  if not saved or #saved.sites == 0 then
    print("No apiary sites known (skipped setup with nothing saved, or none found). Nothing to do.")
    print("Run bee_keeper_setup.run(config) again, or add sites to bee_keeper_sites.dat by hand.")
    -- NOT os.exit() here -- os.exit() unwinds via a special OpenOS sentinel
    -- that this file's xpcall would otherwise catch and misreport as
    -- "FATAL: table: 0x...", since it looks just like any other thrown
    -- error from inside main(). Returning a plain status instead lets the
    -- caller below decide to exit AFTER xpcall has already returned
    -- cleanly, so this expected/intentional exit never gets logged as a
    -- crash.
    return "no_sites"
  end

  config.sites = M.loadSites(saved.sites, config.siteOverrides)
  -- Bee-storage network (autoscanned): the whole list of stores, falling back to
  -- the single legacy storagePos. Honey drawer/barrel is a SEPARATE scanned block.
  config.storagePositions = config.storagePositions or saved.storagePositions
  config.bankStoragePositions = config.bankStoragePositions or saved.bankStoragePositions
  config.storagePos = config.storagePos or saved.storagePos
  config.honeyStoragePos = config.honeyStoragePos or saved.honeyStoragePos
  config.trashPos = config.trashPos or saved.trashPos
  config.workingSlots = M.resolveWorkingSlots(config)

  -- Load the GTNH mutation graph (bee_mutations.dat) for any "mutation"
  -- site's tree planner. Only bother if something actually needs it, and
  -- treat a missing/unreadable dump as non-fatal -- mutation sites will
  -- just report they have no graph rather than crashing the whole run.
  local needsGraph, needsTemplates = false, false
  for _, s in ipairs(config.sites) do
    -- mutation/rainbow plan breeding trees over the graph; traitmax uses it too
    -- (Phase A acquires donor species), plus the allele templates (which donors).
    if s.mode == "mutation" or s.mode == "rainbow" or s.mode == "traitmax" then needsGraph = true end
    if s.mode == "traitmax" then needsTemplates = true end
  end
  if needsGraph then
    local graph, err = M.loadMutationGraph(config)
    if graph then
      local n = 0
      for _ in pairs(graph.byResult) do n = n + 1 end
      print(string.format("Loaded mutation graph: %d producible species.", n))
    else
      print("WARNING: could not load bee_mutations.dat (" .. tostring(err) ..
        ") -- mutation/rainbow/traitmax sites cannot plan breeding trees until it's present.")
    end
  end
  if needsTemplates then
    local tmpl, err = M.loadTemplates(config)
    if tmpl then
      local n = 0
      for _ in pairs(tmpl) do n = n + 1 end
      print(string.format("Loaded allele templates: %d species (traitmax donor data).", n))
    else
      print("WARNING: could not load bee_templates.dat (" .. tostring(err) ..
        ") -- traitmax runs as plain quality breeding (no mutation-acquired donors).")
    end
  end

  -- TRACE EXPORT: write one bee_trace snapshot per task boundary so a live
  -- Minecraft run produces exactly the file bee_keeper_scenario_sim consumes
  -- (`replay <dir>`) to import inheritance RNG and validate every other action.
  local curCycle = 0
  local traceWriter, captureAndWrite = nil, function() end
  if traceDir then
    local T = require("bee_trace")
    local component = require("component")
    local sides = require("sides")
    local invCtrl = component.inventory_controller
    local tracePath = T.pathInDir(traceDir)
    traceWriter = T.writer(io.open, tracePath)
    print("Trace export -> " .. tracePath)

    -- Sites keyed by "x:z" so a snapshot can tell when the robot is ABOVE an
    -- apiary (the only time it can observe that apiary's queen/drone/output),
    -- matching the sim's apiaryKeyOver().
    local siteByPos = {}
    for _, s in ipairs(config.sites) do siteByPos[s.x .. ":" .. s.z] = s end

    -- BIRTH DETECTION: Minecraft does the mating, so offspring genomes are only
    -- observable as the bees harvested out of an apiary. harvestSite hands us
    -- the raw stacks; expand each by stack size into individual offspring recs
    -- (a stacked drone slot = N identical offspring), princess first to match
    -- the sim's offspring[1]=new-princess convention.
    local pendingBirths = {}
    M.traceOnHarvest = function(key, stacks)
      local recs = {}
      for _, st in ipairs(stacks) do
        local one = {}
        for k, v in pairs(st) do one[k] = v end
        one.size = 1
        local rec = T.beeRecord(one)
        for _ = 1, (st.size or 1) do recs[#recs + 1] = rec end
      end
      table.sort(recs, function(a, b)
        local ra = (a.kind == "princess") and 0 or 1
        local rb = (b.kind == "princess") and 0 or 1
        return ra < rb
      end)
      pendingBirths[#pendingBirths + 1] = { key = key, recs = recs }
    end

    captureAndWrite = function()
      local pos = Nav.getPos()
      local snap = { cycle = curCycle, step = Status.get().step,
        pos = { x = pos.x, z = pos.z }, sel = false, cargo = {} }
      for _, entry in ipairs(M.listCargo(config)) do
        local rec = T.beeRecord(entry.stack)
        if rec then snap.cargo[entry.slot] = rec end
      end
      local key = pos.x .. ":" .. pos.z
      if siteByPos[key] then
        local down = sides.down
        local ap = { key = key, out = {} }
        local q = invCtrl.getStackInSlot(down, 1); if q then ap.queen = T.beeRecord(q) end
        local d = invCtrl.getStackInSlot(down, 2); if d then ap.drone = T.beeRecord(d) end
        local size = invCtrl.getInventorySize(down) or 15
        for slot = 3, size do
          local s = invCtrl.getStackInSlot(down, slot)
          local rec = s and T.beeRecord(s)
          if rec then ap.out[slot] = rec end
        end
        snap.apiary = ap
      end
      if #pendingBirths > 0 then snap.births = pendingBirths; pendingBirths = {} end
      traceWriter.step(snap)
    end
  end

  if uiEnabled then
    local UI = require("bee_keeper_ui")
    local computer = require("computer")
    local extras = { chargerPos = config.chargerPos, storagePos = config.storagePos, trashPos = config.trashPos }

    -- Redraw on every status change, not just once per cycle -- since
    -- Status.setStep is already called at every meaningful action boundary
    -- (flying, harvesting, analyzing, evaluating drones, loading a pair,
    -- charging), this makes the dashboard genuinely live without threading.
    --
    -- Storage contents aren't shown here (nil): reading an external
    -- inventory is side-relative from wherever the drone currently is, so
    -- there's no way to know what's in storage without actually being
    -- there -- unlike cargo (the drone's own inventory has no such
    -- constraint). The local simulator can cheat and show it live; real
    -- hardware can't.
    Status.onChange = function()
      local ok, chargePercent = pcall(function() return computer.energy() / computer.maxEnergy() end)
      UI.draw(config.sites, Nav.getPos(), extras, Status.get(), ok and chargePercent or nil, M.listCargo(config), nil)
      captureAndWrite() -- record this task's state to the trace (no-op unless tracing)
      checkStep() -- pause after drawing this task's frame (no-op unless step mode)
    end
    Status.setStep("Starting up")
  else
    print(string.format("Managing %d apiary site(s)%s.", #config.sites,
      config.storagePos and (string.format(", storage at (%d,%d)", config.storagePos.x, config.storagePos.z)) or " (no storage location known)"))
    if stepEnabled or traceDir then
      -- No dashboard: print each task, record it to the trace, then (in step
      -- mode) prompt to single-step it.
      Status.onChange = function()
        print("  [" .. Status.get().step .. "]")
        captureAndWrite()
        checkStep()
      end
    end
  end

  while true do
    curCycle = curCycle + 1
    local log = M.runCycle(config)
    -- Always record each cycle's status lines to the log. In UI mode we don't
    -- want them scribbling over the dashboard, but they still MUST reach
    -- bee_keeper.log -- otherwise a `ui` run leaves the log with zero scheduler
    -- decisions (only startup + stray diag prints), which is exactly what made
    -- live behaviour undiagnosable. realLogLine writes straight to the file
    -- without touching the screen; plain print (which is tee'd) is used when
    -- there's no dashboard to protect.
    for _, line in ipairs(log) do
      if uiEnabled then
        if logFile then logFile:write(tostring(line) .. "\n"); logFile:flush() end
      else
        print(line)
      end
    end
    -- NOT a fixed real-time delay -- each cycle's actual work (walking,
    -- polling beekeeper.getBeeProgress, swapping bees) already costs real
    -- game time via OpenComputers' own component-call yielding, so a flat
    -- multi-second sleep on top of that only adds latency for no benefit.
    -- This is the minimum yield OpenComputers needs to avoid a "too long
    -- without yielding" VM error on a cycle that happens to do nothing at
    -- all (every site already visited this tick, nothing to swap/harvest)
    -- -- everything else about pacing comes from the real actions
    -- themselves, not from waiting here.
    os.sleep(0.05)
  end
end

local ok, result = xpcall(main, debug.traceback, scriptArgs)
if not ok then
  print("FATAL: " .. tostring(result))
end
if logFile then
  logFile:close()
end
if not ok then
  error(result, 0)
elseif result == "no_sites" then
  os.exit(1)
end
