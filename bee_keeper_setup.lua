--[[
  Bee Keeper Setup
  -----------------
  Interactive first-run area scan: ask for an X*Z area at the drone's
  current Y level, preview the boundary (ASCII + fly-the-4-corners with a
  light flash), then sweep the whole area in a boustrophedon (zigzag)
  pattern -- same traversal shape as GTNH-CropAutomation's farm-slot
  pattern -- identifying apiary and storage-container blocks via the
  Geolyzer (component.geolyzer.analyze(sides.down), same call scanner.lua
  uses for crop identification). Discovered positions are persisted so
  this only needs to run once; skip entirely if a saved file already
  exists, or by entering nothing when prompted.

  BLOCK IDENTIFICATION IS UNCONFIRMED -- I don't have decompiled Forestry
  source to read off the exact block registry names, so
  config.apiaryBlockNames / config.storageBlockNames are best-guess
  defaults you should verify. Use M.probeBlockBelow() (see bottom) to
  print the real geolyzer.analyze() result while hovering over a KNOWN
  apiary or storage block, and adjust the config's name lists to match --
  exactly the same "verify against real data" step that caught the
  species/tolerance/flowerProvider mismatches in bee_trait_config.lua
  earlier in this project.
--]]

local Nav = require("bee_keeper_nav")

local M = {}

local function component() return require("component") end
local function sides() return require("sides") end
local function serialization() return require("serialization") end

-- ============================================================
-- Persistence (same loadFile/saveFile convention as the old beeManager.lua)
-- ============================================================

local function loadFile(fileName)
  local f = io.open(fileName, "r")
  if f == nil then return nil end
  local data = f:read("*all")
  f:close()
  return serialization().unserialize(data)
end

local function saveFile(fileName, data)
  local f = io.open(fileName, "w")
  f:write(serialization().serialize(data))
  f:close()
end

M.SITES_FILE = "bee_keeper_sites.dat"

-- ============================================================
-- Block classification
-- ============================================================

-- names: array of exact-match block name strings (see header notes on
-- these being unconfirmed defaults), or nil if that category isn't
-- configured at all (e.g. an older config without trashBlockNames).
local function matchesAny(blockName, names)
  if not blockName or not names then return false end
  for _, n in ipairs(names) do
    if blockName == n then return true end
  end
  return false
end

-- Case-insensitive SUBSTRING match of any of `patterns` against any of the given
-- name strings. Used for honey drawers/barrels, whose block registry name varies
-- by mod but whose inventory name reliably contains "drawer"/"barrel".
local DEFAULT_HONEY_NAMES = { "barrel", "drawer" }
local function nameLooksLike(patterns, ...)
  patterns = patterns or DEFAULT_HONEY_NAMES
  for _, s in ipairs({ ... }) do
    if s then
      local ls = tostring(s):lower()
      for _, p in ipairs(patterns) do
        if ls:find(tostring(p):lower(), 1, true) then return true end
      end
    end
  end
  return false
end

-- Pure block classifier (testable). Given the geolyzer block name plus the
-- inventory_controller name/size seen at that cell, decide what the block is:
--   "apiary" | "trash" | "honey" | "storage" | nil (uninteresting).
-- Order matters: apiaries/trash are matched by their geolyzer block name FIRST
-- (they're inventories too), THEN the honeydew drawer/barrel (kept separate --
-- config.honeyStoreNames, default barrel/drawer), and everything else that is a
-- real inventory (or a configured storage block name) is BEE storage. This is
-- why the barrel is "always honey": it matches the honey rule before the generic
-- storage rule.
function M.classifyBlock(config, blockName, invName, invSize)
  if matchesAny(blockName, config.apiaryBlockNames) then return "apiary" end
  if matchesAny(blockName, config.trashBlockNames) then return "trash" end
  if nameLooksLike(config.honeyStoreNames, blockName, invName) then return "honey" end
  if (invSize and invSize > 0) or matchesAny(blockName, config.storageBlockNames) then return "storage" end
  return nil
end

-- Prints the raw geolyzer.analyze() result for the block directly below
-- the drone's CURRENT position -- call this manually while hovering over
-- a known apiary or storage block to get the real name string for your
-- config, before trusting the automated scan.
function M.probeBlockBelow()
  local result = component().geolyzer.analyze(sides().down)
  print("geolyzer.analyze(down) result:")
  for k, v in pairs(result) do
    print(string.format("  %s = %s", tostring(k), tostring(v)))
  end
  return result
end

-- Prints (and writes to inventory_probe.log, so it's readable without
-- relying on bee_keeper_manager_run.lua's print-logging being active --
-- this is meant to be called standalone, e.g. from the lua> REPL via
-- `require("bee_keeper_setup").probeInventoryBelow()`) every slot 1..N of
-- the inventory directly below the drone's CURRENT position, where N is
-- whatever inventory_controller.getInventorySize(down) reports. Call this
-- while hovering over an apiary that visibly has a princess/drone/combs
-- sitting in it (per the in-game GUI) to find out which slot numbers they
-- ACTUALLY occupy -- config.productSlots (7-15) was inherited from the
-- old Transposer-based script and isn't confirmed correct for every
-- apiary tier/mod version; harvestSite silently pulling nothing is
-- exactly the symptom of that range being wrong for a given real apiary.
-- Console output is a GROUPED summary (one line per distinct
-- name/label/size combination, listing which slots share it) instead
-- of one line per individual slot -- a container mostly full of
-- identical stacks (the common case: a barrel full of honey, or an
-- apiary's output slots full of the same drone) otherwise overflows a
-- small in-game terminal with 20+ near-duplicate lines and no way to
-- scroll back. The FULL per-slot detail (every slot, empty or not)
-- always goes to inventory_probe.log regardless -- this project already
-- mirrors the OC filesystem to your real disk (same as every other log
-- this whole debugging session has read), so that file is readable in
-- any normal text editor with no console scrollback limit at all.
function M.probeInventoryBelow()
  local ic = component().inventory_controller
  local down = sides().down
  local size = ic.getInventorySize(down)

  local lines = { string.format("inventory_controller.getInventorySize(down) = %s", tostring(size)) }
  local groups, groupOrder, emptyCount = {}, {}, 0

  for slot = 1, (size or 0) do
    local stack = ic.getStackInSlot(down, slot)
    if stack then
      table.insert(lines, string.format("  slot %d: %s x%s (%s)",
        slot, tostring(stack.name), tostring(stack.size), tostring(stack.label)))
      local key = tostring(stack.name) .. "|" .. tostring(stack.label) .. "|" .. tostring(stack.size)
      if not groups[key] then
        groups[key] = { name = stack.name, label = stack.label, size = stack.size, slots = {} }
        table.insert(groupOrder, key)
      end
      table.insert(groups[key].slots, slot)
    else
      table.insert(lines, string.format("  slot %d: empty", slot))
      emptyCount = emptyCount + 1
    end
  end

  print(string.format("inventory_controller.getInventorySize(down) = %s", tostring(size)))
  for _, key in ipairs(groupOrder) do
    local g = groups[key]
    local slotDesc = #g.slots <= 4
      and ("slot" .. (#g.slots > 1 and "s " or " ") .. table.concat(g.slots, ","))
      or string.format("%d slots (e.g. %d,%d,%d,...)", #g.slots, g.slots[1], g.slots[2], g.slots[3])
    print(string.format("  %s: %s x%s (%s)", slotDesc, tostring(g.name), tostring(g.size), tostring(g.label)))
  end
  if emptyCount > 0 then
    print(string.format("  %d slot(s) empty", emptyCount))
  end
  print(string.format("Full per-slot detail (%d lines) written to inventory_probe.log -- open that in a text editor for the exhaustive version.", #lines))

  local f = io.open("inventory_probe.log", "w")
  if f then
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
  end

  return lines
end

-- ============================================================
-- Interactive prompts
-- ============================================================

local function promptNumber(question, allowBlankSkip)
  io.write(question)
  local line = io.read()
  if line == nil or line == "" then
    return nil
  end
  local n = tonumber(line)
  if n == nil then
    print("Not a number, try again.")
    return promptNumber(question, allowBlankSkip)
  end
  return n
end

local function promptYesNo(question, default)
  io.write(question)
  local line = io.read()
  if line == nil or line == "" then return default end
  line = line:lower()
  return line == "y" or line == "yes"
end

-- ============================================================
-- Border preview
-- ============================================================

-- Both the ASCII label below and flyBorderPreview's corners describe the
-- LAST CELL sweepCells(width, depth) actually visits, i.e. (width-1,
-- depth-1) -- sweepCells iterates x=0..width-1, z=0..depth-1 (a WxD
-- grid, 0-indexed), so the far corner is one block SHORT of (width,
-- depth). Using (width, depth) directly here showed the boundary a
-- full block past where the real scan ever reaches -- confirmed as a
-- real, reported bug: block placement based on this preview could sit
-- just outside the area actually swept, never getting discovered at
-- all (e.g. a storage container placed at the previewed-but-not-
-- actually-scanned far corner).
local function printAsciiPreview(width, depth)
  print(string.format("Planned scan area: %d x %d (starting at the drone's current position, (0,0)):", width, depth))
  local maxCols = 40
  local scaleX = width > maxCols and (maxCols / width) or 1
  local scaleZ = depth > (maxCols / 2) and ((maxCols / 2) / depth) or 1
  local cols = math.max(2, math.floor(width * scaleX))
  local rows = math.max(1, math.floor(depth * scaleZ))

  print(" (0,0) +" .. string.rep("-", cols) .. "+")
  for _ = 1, rows do
    print("       |" .. string.rep(" ", cols) .. "|")
  end
  print("       +" .. string.rep("-", cols) .. string.format("+ (%d,%d)", width - 1, depth - 1))
end

-- Walks to all 4 corners of the planned area (relative to current
-- position as origin), signaling at each, then returns to the start.
-- Lets you visually confirm the boundary in-world before committing to
-- the full sweep. Signal is a light flash (component.drone) if that
-- component exists, or a beep (component.computer, on any host
-- including a Robot) otherwise -- checked once, not per corner. Corners
-- use width-1/depth-1 (the actual last scanned cell -- see
-- printAsciiPreview's header notes), not width/depth directly.
local function flyBorderPreview(width, depth)
  local maxX, maxZ = width - 1, depth - 1
  local corners = { { 0, 0 }, { maxX, 0 }, { maxX, maxZ }, { 0, maxZ }, { 0, 0 } }

  local d = component().isAvailable("drone") and component().drone or nil
  local originalColor = d and d.getLightColor()
  local beep = component().isAvailable("computer") and component().computer.beep or nil

  local function signal()
    if d then
      d.setLightColor(0x00FF00)
      os.sleep(0.5)
      d.setLightColor(0xFF0000)
      os.sleep(0.5)
    elseif beep then
      beep(1000, 0.2)
    end
  end

  for i, c in ipairs(corners) do
    print(string.format("Walking to corner %d/%d: (%d, %d)", i, #corners, c[1], c[2]))
    local ok, reason = Nav.gotoXZ(c[1], c[2])
    if not ok then
      print("  Could not reach corner: " .. tostring(reason))
    else
      signal()
    end
  end
  if d then d.setLightColor(originalColor) end
end
M.flyBorderPreview = flyBorderPreview

-- ============================================================
-- Area sweep
-- ============================================================

-- Boustrophedon (zigzag) cell order -- same traversal shape as
-- GTNH-CropAutomation's workingSlotToPos, adapted to arbitrary width/depth
-- instead of a fixed square.
local function sweepCells(width, depth)
  local cells = {}
  for x = 0, width - 1 do
    if x % 2 == 0 then
      for z = 0, depth - 1 do table.insert(cells, { x, z }) end
    else
      for z = depth - 1, 0, -1 do table.insert(cells, { x, z }) end
    end
  end
  return cells
end

-- Sweeps the whole area, classifying the block below at each cell.
-- Returns { apiarySites = {...}, storageSites = {...}, honeySites = {...},
-- trashSites = {...} } (each a list of {x,z}). Storage is autoscanned: a barrel/
-- drawer becomes HONEY storage, every other inventory becomes BEE storage.
function M.scanArea(config, width, depth)
  local geolyzer = component().geolyzer
  local ic = component().inventory_controller
  local downSide = sides().down

  local apiarySites, storageSites, honeySites, trashSites = {}, {}, {}, {}
  local cells = sweepCells(width, depth)

  for i, cell in ipairs(cells) do
    local ok = Nav.gotoXZ(cell[1], cell[2])
    if ok then
      local result = geolyzer.analyze(downSide)
      local blockName = result and result.name
      -- The inventory name/size are the reliable signal for storage vs honey
      -- (the drawer reports "tile.fullDrawers1", the apiarist chest
      -- "tile.for.apicultureChest") -- geolyzer block names vary by mod and
      -- aren't all confirmed. Guarded: a non-inventory block just yields nil.
      local okN, invName = pcall(function() return ic.getInventoryName(downSide) end)
      local okS, invSize = pcall(function() return ic.getInventorySize(downSide) end)
      local cat = M.classifyBlock(config, blockName, okN and invName or nil, okS and invSize or nil)
      if cat == "apiary" then table.insert(apiarySites, { x = cell[1], z = cell[2] })
      elseif cat == "trash" then table.insert(trashSites, { x = cell[1], z = cell[2] })
      elseif cat == "honey" then table.insert(honeySites, { x = cell[1], z = cell[2] })
      elseif cat == "storage" then table.insert(storageSites, { x = cell[1], z = cell[2] }) end
    else
      print(string.format("Skipped cell (%d,%d): could not reach it", cell[1], cell[2]))
    end

    if i % 10 == 0 then
      print(string.format("Scanned %d/%d cells -- %d apiaries, %d bee storage, %d honey, %d trash so far",
        i, #cells, #apiarySites, #storageSites, #honeySites, #trashSites))
    end
  end

  return { apiarySites = apiarySites, storageSites = storageSites,
    honeySites = honeySites, trashSites = trashSites }
end

-- ============================================================
-- Main entry point
-- ============================================================

-- config: needs apiaryBlockNames, storageBlockNames, honeyStoreNames,
-- trashBlockNames (see header notes). Returns the saved-sites table ({ sites,
-- storagePositions = {...}, storagePos, honeyStoragePos, trashPos, width, depth }),
-- or nil if the user skipped setup with no existing file to fall back on.
function M.run(config)
  local existing = loadFile(M.SITES_FILE)
  if existing then
    local nStore = existing.storagePositions and #existing.storagePositions
      or (existing.storagePos and 1) or 0
    print(string.format("Found existing site config (%d apiaries, %d bee-storage, honey %s, trash %s). Press Enter to keep it, or type 'rescan' to redo:",
      #existing.sites, nStore, existing.honeyStoragePos and "found" or "not found",
      existing.trashPos and "found" or "not found"))
    local line = io.read()
    if line ~= "rescan" then
      return existing
    end
  end

  local width = promptNumber("Scan width, X blocks (blank to skip setup): ")
  if width == nil then
    return existing -- nil if there was nothing saved either
  end
  local depth = promptNumber("Scan depth, Z blocks: ")
  if depth == nil then
    print("No depth given, aborting setup.")
    return existing
  end

  Nav.setHome(nil) -- altitude locked to wherever the drone currently is
  printAsciiPreview(width, depth)

  if config.showBorderPreview ~= false then
    flyBorderPreview(width, depth)
  end

  if not promptYesNo("Does the boundary look right? [Y/n]: ", true) then
    print("Aborted -- rerun setup once you've repositioned.")
    return existing
  end

  print("Scanning...")
  local result = M.scanArea(config, width, depth)
  Nav.gotoXZ(0, 0)

  local sites = {}
  for i, s in ipairs(result.apiarySites) do
    table.insert(sites, { name = "site" .. i, x = s.x, z = s.z, mode = "traitmax" })
  end

  -- ALL bee-storage blocks make up the storage network (the robot fills one and
  -- spills into the next); storagePos stays set to the first for backward compat.
  local storagePositions = result.storageSites
  local storagePos = storagePositions[1]
  print(string.format("Found %d bee-storage block(s).", #storagePositions))

  -- Designate ONE block as the dedicated BANK chest (holds the inviolable purebred
  -- reserve the climb never spends). Only offered when there's more than one store,
  -- since a lone store has to hold everything. Blank keeps the older count-only
  -- reserve protection with no physical separation.
  local bankStoragePositions = nil
  if #storagePositions >= 2 then
    print("Which bee-storage block is the dedicated BANK (holds the inviolable purebred reserve)?")
    for i, p in ipairs(storagePositions) do
      print(string.format("  %d: (%d,%d)", i, p.x, p.z))
    end
    local idx = promptNumber("Bank block # (blank = no dedicated bank chest): ", true)
    if idx and storagePositions[idx] then
      bankStoragePositions = { storagePositions[idx] }
      print(string.format("Bank = block %d at (%d,%d); the other %d store(s) are working.",
        idx, storagePositions[idx].x, storagePositions[idx].z, #storagePositions - 1))
    else
      print("No dedicated bank chest -- using count-only reserve protection.")
    end
  end

  -- The honeydew barrel/drawer is separate storage. First one found wins.
  local honeyStoragePos = result.honeySites[1]
  if #result.honeySites > 1 then
    print(string.format("Found %d honey barrels/drawers, using the first at (%d,%d). Edit %s to change.",
      #result.honeySites, honeyStoragePos.x, honeyStoragePos.z, M.SITES_FILE))
  end

  local trashPos = result.trashSites[1]
  if #result.trashSites > 1 then
    print(string.format("Found %d trash can candidates, using the first at (%d,%d). Edit %s to change.",
      #result.trashSites, trashPos.x, trashPos.z, M.SITES_FILE))
  end

  local saved = { sites = sites, storagePositions = storagePositions, storagePos = storagePos,
    bankStoragePositions = bankStoragePositions,
    honeyStoragePos = honeyStoragePos, trashPos = trashPos, width = width, depth = depth }
  saveFile(M.SITES_FILE, saved)
  print(string.format("Saved %d apiary site(s), %d bee-storage block(s)%s%s to %s.",
    #sites, #storagePositions,
    honeyStoragePos and " and a honey drawer" or " (no honey drawer found)",
    trashPos and " and 1 trash can" or " (no trash can found)", M.SITES_FILE))
  print("Every discovered site defaults to traitmax mode -- edit " .. M.SITES_FILE ..
    " (or bee_keeper_manager_config.lua's siteOverrides) to assign species/mutation targets.")

  return saved
end

return M
