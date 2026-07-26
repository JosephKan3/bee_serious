--[[
  Installer for the bee_serious drone. Pattern adapted from
  Level-Maintainer's installer.lua (github.com/Armagedon13/Level-Maintainer)
  -- known-working wget-based install + config-preservation approach.

  Run on the drone with:
    wget https://raw.githubusercontent.com/JosephKan3/bee_serious/main/installer.lua && installer

  The file list is NOT hardcoded here. It lives in bee_files.lua (the single
  source of truth shared with updater.lua). This installer bootstraps that
  manifest first, then downloads everything it names. Keeping one list means a
  fresh install can never again pull the manager without its dependencies (the
  "module 'bee_mutation_graph' not found" crash).
--]]

local shell = require("shell")
local filesystem = require("filesystem")

local repo = "https://raw.githubusercontent.com/JosephKan3/bee_serious/"
local branch = "main"

local function urlFor(file)
  return repo .. branch .. "/" .. file
end

local function pathFor(file)
  return shell.getWorkingDirectory() .. "/" .. file
end

-- Download a file, replacing any existing copy. Returns success boolean.
local function download(file)
  local path = pathFor(file)
  if filesystem.exists(path) then
    filesystem.remove(path)
  end
  return shell.execute("wget -fq " .. urlFor(file) .. " " .. path)
end

print("Installing bee_serious...")

-- Bootstrap the manifest itself before anything else can reference it.
print("Fetching file manifest (bee_files.lua)...")
if not download("bee_files.lua") then
  print("FATAL: could not download bee_files.lua -- aborting.")
  print("Check the internet card and network connection, then re-run installer.")
  return
end

local manifest = dofile(pathFor("bee_files.lua"))

-- Code + data: always (re)downloaded. bee_files.lua is already in the code
-- list, so it gets a redundant-but-harmless second fetch -- fine, it keeps the
-- "code is exactly the manifest" invariant obvious.
for _, file in ipairs(manifest.code) do
  print("Downloading " .. file .. "...")
  download(file)
end

for _, file in ipairs(manifest.data) do
  print("Downloading " .. file .. "...")
  download(file)
end

-- Preserved files are USER data -- a default is fetched only if absent, and an
-- existing copy is left untouched (e.g. a reinstall after an update).
for _, file in ipairs(manifest.preserved) do
  local path = pathFor(file)
  if not filesystem.exists(path) then
    if file:match("%.lua$") then
      print("Downloading default " .. file .. "...")
      download(file)
    end
    -- Non-.lua preserved files (e.g. bee_keeper_sites.dat) have no repo
    -- default -- they are generated on first run, not downloaded.
  else
    print(file .. " already exists - preserved")
  end
end

print("\nInstallation complete!")
print("Run 'bee_keeper_manager_run' to start (add 'ui' to show the live dashboard).")
