--[[
  Updater for the bee_serious drone. Pattern adapted from
  Level-Maintainer's updater.lua (github.com/Armagedon13/Level-Maintainer):
  compares local version.lua against the repo's, prompts before touching
  anything, and NEVER overwrites config.lua or the persisted site scan.
--]]

local component = require("component")
local shell = require("shell")
local filesystem = require("filesystem")
local term = require("term")

local Updater = {}

function Updater.new()
  local obj = {}
  obj.repository = "JosephKan3/bee_serious"
  obj.branch = "main"
  obj.currentVersion = Updater.getCurrentVersion()

  setmetatable(obj, { __index = Updater })
  return obj
end

-- Get current local version
function Updater.getCurrentVersion()
  local versionPath = shell.getWorkingDirectory() .. "/version.lua"
  if not filesystem.exists(versionPath) then
    return { programVersion = "0.0.0" }
  end

  local success, version = pcall(dofile, versionPath)
  if success and version then
    return version
  end
  return { programVersion = "0.0.0" }
end

-- Get latest version from GitHub
function Updater:getLatestVersion()
  if not component.isAvailable("internet") then
    return nil, "Internet card not found"
  end

  local internet = require("internet")
  local url = "https://raw.githubusercontent.com/" .. self.repository .. "/refs/heads/" .. self.branch .. "/version.lua"

  local request = internet.request(url)
  if not request then
    return nil, "Failed to connect to GitHub"
  end

  local result = ""
  for chunk in request do
    result = result .. chunk
  end

  local success, remoteVersion = pcall(load(result))
  if not success or not remoteVersion then
    return nil, "Failed to parse remote version"
  end

  return remoteVersion
end

-- Check if update is needed
function Updater:isUpdateNeeded()
  local remoteVersion, err = self:getLatestVersion()
  if not remoteVersion then
    return false, nil, err
  end

  -- Compare program versions (remove non-digits for comparison)
  local currentProgramVersion = self.currentVersion.programVersion:gsub("[%D]", "")
  local latestProgramVersion = remoteVersion.programVersion:gsub("[%D]", "")

  local isProgramUpdateNeeded = tonumber(latestProgramVersion) > tonumber(currentProgramVersion)

  return isProgramUpdateNeeded, remoteVersion
end

-- Download and update files. NEVER touches bee_keeper_manager_config.lua or
-- bee_keeper_sites.dat -- those are user data (config + your area scan).
function Updater:downloadFiles()
  local repo = "https://raw.githubusercontent.com/" .. self.repository .. "/" .. self.branch .. "/"

  local files = {
    "bee_breeding.lua",
    "bee_trait_config.lua",
    "bee_keeper_nav.lua",
    "bee_keeper_setup.lua",
    "bee_keeper_status.lua",
    "bee_keeper_ui.lua",
    "bee_keeper_manager.lua",
    "bee_keeper_manager_run.lua",
    "updater.lua",
    "version.lua",
    -- Real GTNH mutation graph + species list, dumped once from a stationary
    -- Adapter next to an apiary (see docs/oc_forestry_api.md). Shipped to the
    -- robot as static data since the robot has no bee_housing component of its
    -- own -- it never queries the graph live.
    "bee_mutations.dat",
    "bee_species.dat",
  }

  print("Downloading files...")
  for _, file in ipairs(files) do
    local url = repo .. file
    local path = shell.getWorkingDirectory() .. "/" .. file

    if filesystem.exists(path) then
      filesystem.remove(path)
    end

    local success = shell.execute("wget -fq " .. url .. " " .. path)
    if success then
      print("  [ok] " .. file)
    else
      print("  [FAILED] " .. file)
    end
  end
end

-- Main update function
function Updater:checkAndUpdate(silent)
  local isProgramUpdate, remoteVersion, err = self:isUpdateNeeded()

  if err then
    if not silent then
      print("Update check failed: " .. err)
    end
    return false
  end

  if not isProgramUpdate then
    if not silent then
      print("Already up to date (v" .. self.currentVersion.programVersion .. ")")
    end
    return false
  end

  -- New version available -- always prompts, regardless of silent.
  term.clear()
  term.setCursor(1, 1)
  print("===========================================")
  print("  New version available!")
  print("===========================================")
  print("Current version: " .. self.currentVersion.programVersion)
  print("Latest version:  " .. remoteVersion.programVersion)
  print("")

  io.write("Do you want to update? (y/n): ")
  local answer = io.read()

  if not answer or answer:lower() ~= "y" then
    print("Update cancelled")
    return false
  end

  print("\nDownloading updates...")
  self:downloadFiles()

  print("\nUpdate complete!")
  print("Your config and site scan were NOT modified.")
  print("\nRebooting...")
  os.sleep(2)
  shell.execute("reboot")

  return true
end

-- Run updater when executed directly
local args = { ... }
local silent = false

if args and #args > 0 then
  silent = args[1] == "silent" or args[1] == "-s"
end

local updater = Updater.new()
updater:checkAndUpdate(silent)
