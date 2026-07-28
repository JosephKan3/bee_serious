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

-- Parse a dotted version string ("0.6.16") into a list of numeric components
-- {0, 6, 16}. Missing/garbage components read as 0.
local function parseVersion(v)
  local parts = {}
  for n in tostring(v or ""):gmatch("%d+") do
    parts[#parts + 1] = tonumber(n)
  end
  return parts
end

-- Semantic (per-component) comparison: returns true iff a > b.
-- Compares component-by-component so 0.7.0 > 0.6.16 (7 > 6 wins at the minor
-- position) instead of the old digit-strip that made "070" < "0616".
local function versionGreater(a, b)
  local pa, pb = parseVersion(a), parseVersion(b)
  local n = math.max(#pa, #pb)
  for i = 1, n do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end
Updater.versionGreater = versionGreater

-- Check if update is needed
function Updater:isUpdateNeeded()
  local remoteVersion, err = self:getLatestVersion()
  if not remoteVersion then
    return false, nil, err
  end

  local isProgramUpdateNeeded =
    versionGreater(remoteVersion.programVersion, self.currentVersion.programVersion)

  return isProgramUpdateNeeded, remoteVersion
end

-- Download and update files. NEVER touches the `preserved` files (config +
-- your area scan) -- those are user data. The file list comes from
-- bee_files.lua, the single source of truth shared with installer.lua, so the
-- two can't drift apart and leave a module unshipped.
function Updater:downloadFiles()
  local repo = "https://raw.githubusercontent.com/" .. self.repository .. "/" .. self.branch .. "/"

  local function download(file)
    local url = repo .. file
    local path = shell.getWorkingDirectory() .. "/" .. file
    if filesystem.exists(path) then
      filesystem.remove(path)
    end
    return shell.execute("wget -fq " .. url .. " " .. path)
  end

  -- Refresh the manifest itself FIRST so a newly-added module in this release
  -- is downloaded in the same pass (bee_files.lua is also in `code`, but we
  -- need it fetched before we can read the up-to-date list).
  print("Refreshing file manifest...")
  download("bee_files.lua")
  local manifest = dofile(shell.getWorkingDirectory() .. "/bee_files.lua")

  print("Downloading files...")
  for _, file in ipairs(manifest.code) do
    print((download(file) and "  [ok] " or "  [FAILED] ") .. file)
  end
  for _, file in ipairs(manifest.data) do
    print((download(file) and "  [ok] " or "  [FAILED] ") .. file)
  end
  -- manifest.preserved is intentionally NOT touched -- user data.
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
