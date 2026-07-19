--[[
  Entry point: runs area setup (if needed, or on request), loads the
  config, merges in the discovered sites, and runs bee_keeper_manager
  forever. Run this ON the drone with the beekeeper + inventory_controller
  upgrades installed, hovering at the Y level you want it to operate at.
--]]

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
local config = require("bee_keeper_manager_config")

Nav.setHome(nil) -- locks flight altitude to wherever the drone currently is

local saved = Setup.run(config)
if not saved or #saved.sites == 0 then
  print("No apiary sites known (skipped setup with nothing saved, or none found). Nothing to do.")
  print("Run bee_keeper_setup.run(config) again, or add sites to bee_keeper_sites.dat by hand.")
  os.exit(1)
end

config.sites = M.loadSites(saved.sites, config.siteOverrides)
config.storagePos = config.storagePos or saved.storagePos

print(string.format("Managing %d apiary site(s)%s.", #config.sites,
  config.storagePos and (string.format(", storage at (%d,%d)", config.storagePos.x, config.storagePos.z)) or " (no storage location known)"))

while true do
  local log = M.runCycle(config)
  for _, line in ipairs(log) do
    print(line)
  end
  os.sleep(2)
end
