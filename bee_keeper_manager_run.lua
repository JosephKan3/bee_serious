--[[
  Entry point: loads the config and runs bee_keeper_manager forever.
  Run this ON the agent (Robot/Drone) with the beekeeper + inventory_controller
  upgrades installed.
--]]

local M = require("bee_keeper_manager")
local config = require("bee_keeper_manager_config")

while true do
  local log = M.runCycle(config)
  for _, line in ipairs(log) do
    print(line)
  end
  os.sleep(2)
end
