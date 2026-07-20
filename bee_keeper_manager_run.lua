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
  for _, a in ipairs(args) do
    if a == "ui" then uiEnabled = true end
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
  config.storagePos = config.storagePos or saved.storagePos

  if uiEnabled then
    local UI = require("bee_keeper_ui")
    local computer = require("computer")
    local extras = { chargerPos = config.chargerPos, storagePos = config.storagePos }

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
    end
    Status.setStep("Starting up")
  else
    print(string.format("Managing %d apiary site(s)%s.", #config.sites,
      config.storagePos and (string.format(", storage at (%d,%d)", config.storagePos.x, config.storagePos.z)) or " (no storage location known)"))
  end

  while true do
    local log = M.runCycle(config)
    if not uiEnabled then
      for _, line in ipairs(log) do
        print(line)
      end
    end
    os.sleep(2)
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
