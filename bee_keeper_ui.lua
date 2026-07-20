--[[
  Bee Keeper UI
  --------------
  Live grid dashboard shown while bee_keeper_manager_run.lua is running,
  when started with the "ui" argument (see that file). Layout, top to
  bottom: the current action (refreshes every redraw), then a map (left)
  of where the drone and every known object currently are next to a side
  panel (right) listing cargo and storage contents, then a position/charge
  footer.

  M.renderBuffer is a PURE function (world state in, array-of-strings out)
  -- no term/gpu calls -- so the actual layout/scaling/symbol/summary logic
  is testable without a real screen (see bee_keeper_ui_test.lua). M.draw is
  the thin wrapper that blits that buffer to the real terminal.
--]]

local Cfg = require("bee_trait_config")

local M = {}

M.SYMBOLS = {
  traitmax = "T",
  species = "S",
  mutation = "M",
  storage = "$",
  trash = "X",
  charger = "C",
  drone = "@",
}

-- Packed 24-bit RGB, same format component.gpu.setForeground expects. A
-- Tier 1 GPU/screen is monochrome and will quantize these down (no code
-- change needed for that -- the GPU driver itself handles it); real color
-- needs Tier 2+. Apiaries are ALL one color regardless of mode (traitmax/
-- species/mutation still get different SYMBOLS so you can tell them apart
-- by character, just not by color).
M.COLORS = {
  apiary = 0xE0C000, -- yellow, ALL apiaries regardless of mode
  storage = 0x00CFCF, -- cyan
  trash = 0xFF00FF, -- magenta
  -- charger = 0xE0A000, -- amber (distinct from the others)
  charger = 0x00E000, -- light green (distinct from the others)
  drone = 0xE03030, -- red
  default = 0x707070, -- dim grey for the map's empty "." cells
  text = 0xE0E0E0, -- header/footer/panel text
}

-- Reserves this many rows for the action header (+ separator) at the top
-- and the position/charge footer (+ separator) at the bottom; everything
-- else is the map+panel row.
M.STATUS_ROWS = 4

-- How much of the width the map gets; the rest is the side panel.
M.MAP_WIDTH_FRACTION = 0.55

-- Cap on cargo lines in the side panel, so a full hold can't push the
-- storage section off the bottom of the screen.
M.MAX_CARGO_LINES = 6

local function padRight(s, width)
  if #s >= width then return s:sub(1, width) end
  return s .. string.rep(" ", width - #s)
end

-- Computes the (minX,minZ)-(maxX,maxZ) bounding box across every point of
-- interest, so the drone is always visible even if it's currently outside
-- the sites' own bounding box (e.g. flying home to charge).
local function boundingBox(points)
  local minX, maxX, minZ, maxZ = nil, nil, nil, nil
  for _, p in ipairs(points) do
    if minX == nil or p.x < minX then minX = p.x end
    if maxX == nil or p.x > maxX then maxX = p.x end
    if minZ == nil or p.z < minZ then minZ = p.z end
    if maxZ == nil or p.z > maxZ then maxZ = p.z end
  end
  return minX or 0, maxX or 0, minZ or 0, maxZ or 0
end

-- Maps a world (x,z) to a (col,row) within a mapWidth x mapHeight grid, ONE
-- CHARACTER PER BLOCK -- not stretched/scaled to fill the available area.
-- A real 4x6 scanned area should render as a compact 4x6 patch of dots
-- with the rest of the reserved map area left blank, not a screen-sized
-- grid of periods. Clipped (not scaled) if the real area is somehow
-- larger than the available space, so a huge area still degrades
-- gracefully instead of erroring.
local function project(x, z, minX, minZ, mapWidth, mapHeight)
  local col = math.max(1, math.min(mapWidth, x - minX + 1))
  local row = math.max(1, math.min(mapHeight, z - minZ + 1))
  return col, row
end

-- One-line summary of an inventory stack for the cargo/storage panel:
-- species name for an analyzed bee, a generic marker for an unanalyzed
-- one, or the item's own name (honey, etc.) for anything else.
local function summarizeStack(stack)
  if not stack then return nil end
  if stack.individual then
    if not stack.individual.isAnalyzed then return "unanalyzed bee" end
    local species = stack.individual.active and stack.individual.active.species
    return species and Cfg.speciesKey(species) or "bee"
  end
  return stack.name or "item"
end
M.summarizeStack = summarizeStack

-- Builds the full dashboard as an array of `height` strings, each exactly
-- `width` characters, PLUS a sparse list of colored cells to paint over
-- that base text. Pure -- no I/O -- so both are fully testable without a
-- real screen.
--
-- sites: array of { name, x, z, mode }
-- dronePos: { x, z }
-- extras: optional { chargerPos = {x,z}, storagePos = {x,z} }
-- statusInfo: { step = string, history = {string, ...} } (from
--   bee_keeper_status.get())
-- chargePercent: 0..1 or nil
-- droneInventory: optional array of { slot = N, stack = rawStack } for
--   occupied cargo slots (see bee_keeper_manager.lua's M.listInventory)
-- storageInventory: optional, same shape, for the storage chest -- pass
--   nil if unknown (e.g. the drone hasn't visited it yet; there's no way
--   to know an inventory's contents without physically being there)
--
-- Returns rows, placements. placements is an array of
-- { row, col, char, colorKey } -- row/col are 1-indexed positions within
-- `rows` (row already accounts for the header offset), colorKey indexes
-- M.COLORS. M.draw paints the base text in M.COLORS.default/text, then
-- recolors just these cells -- that's what makes each object and the
-- drone visually distinct instead of same-color characters.
function M.renderBuffer(sites, dronePos, extras, statusInfo, chargePercent, width, height, droneInventory, storageInventory)
  extras = extras or {}
  width = width or 50
  height = height or 16
  local contentHeight = math.max(1, height - M.STATUS_ROWS)
  local mapWidth = math.max(10, math.floor(width * M.MAP_WIDTH_FRACTION))
  local panelWidth = width - mapWidth - 1 -- 1-col gap between map and panel
  local rowOffset = 2 -- STEP + separator rows come before the map/panel row

  local points = { { x = dronePos.x, z = dronePos.z } }
  for _, s in ipairs(sites) do table.insert(points, { x = s.x, z = s.z }) end
  if extras.chargerPos then table.insert(points, extras.chargerPos) end
  if extras.storagePos then table.insert(points, extras.storagePos) end
  if extras.trashPos then table.insert(points, extras.trashPos) end

  local minX, maxX, minZ, maxZ = boundingBox(points)

  -- Real block span: one character per block, not stretched to fill the
  -- reserved map area -- see M.draw's header notes on why. Clipped to the
  -- available area (not scaled) so an unusually large scan still degrades
  -- gracefully instead of erroring.
  local spanX = math.max(1, math.min(mapWidth, maxX - minX + 1))
  local spanZ = math.max(1, math.min(contentHeight, maxZ - minZ + 1))

  -- Build the map as a grid of characters, sites first so the drone (drawn
  -- last) always wins any overlap -- both in the text grid and in which
  -- placement gets recorded last for that cell. Only cells within the
  -- real span get a "." background -- anything beyond it is blank
  -- whitespace, not more periods.
  local grid = {}
  for r = 1, contentHeight do
    grid[r] = {}
    for c = 1, mapWidth do
      grid[r][c] = (r <= spanZ and c <= spanX) and "." or " "
    end
  end

  local placements = {}
  local function place(x, z, symbol, colorKey)
    local col, row = project(x, z, minX, minZ, spanX, spanZ)
    grid[row][col] = symbol
    table.insert(placements, { row = row + rowOffset, col = col, char = symbol, colorKey = colorKey })
  end

  if extras.storagePos then place(extras.storagePos.x, extras.storagePos.z, M.SYMBOLS.storage, "storage") end
  if extras.trashPos then place(extras.trashPos.x, extras.trashPos.z, M.SYMBOLS.trash, "trash") end
  if extras.chargerPos then place(extras.chargerPos.x, extras.chargerPos.z, M.SYMBOLS.charger, "charger") end
  for _, s in ipairs(sites) do
    place(s.x, s.z, M.SYMBOLS[s.mode] or "?", "apiary")
  end
  place(dronePos.x, dronePos.z, M.SYMBOLS.drone, "drone")

  -- Side panel: per-apiary progress, then cargo, then storage. Apiaries
  -- go first because that's the actual objective; cargo is capped so a
  -- full hold can't push the storage section off the bottom.
  local panelLines = {}
  local function panelLine(text) table.insert(panelLines, padRight(text, panelWidth)) end

  panelLine("Apiaries:")
  for _, s in ipairs(sites) do
    -- site.progress is a LAST-KNOWN value cached by bee_keeper_manager.lua
    -- on each visit (an apiary's contents can only be read while standing
    -- at it), so "--" means "not visited yet this run", not "0%".
    local pct = s.progress and string.format("%3.0f%%", s.progress * 100) or "  --"
    panelLine(string.format(" %s %s %s", M.SYMBOLS[s.mode] or "?", pct, s.name or "?"))
  end
  if #sites == 0 then panelLine(" (none)") end

  panelLine("")
  panelLine("Cargo:")
  local cargoShown = 0
  for _, entry in ipairs(droneInventory or {}) do
    if cargoShown >= M.MAX_CARGO_LINES then
      panelLine(string.format(" ...+%d more", #droneInventory - cargoShown))
      break
    end
    panelLine(string.format(" %2d: %s", entry.slot, summarizeStack(entry.stack) or "?"))
    cargoShown = cargoShown + 1
  end
  if not droneInventory or #droneInventory == 0 then
    panelLine(" (empty)")
  end

  panelLine("")
  panelLine("Storage:")
  if storageInventory == nil then
    panelLine(" (not visited yet)")
  elseif #storageInventory == 0 then
    panelLine(" (empty)")
  else
    for _, entry in ipairs(storageInventory) do
      panelLine(string.format(" %2d: %s", entry.slot, summarizeStack(entry.stack) or "?"))
    end
  end

  local rows = {}

  -- Current action, refreshed every redraw -- first thing on screen, not
  -- buried at the bottom.
  table.insert(rows, padRight("STEP: " .. (statusInfo and statusInfo.step or "idle"), width))
  table.insert(rows, padRight(string.rep("-", width), width))

  -- Map (left) + panel (right), side by side.
  for r = 1, contentHeight do
    local mapText = table.concat(grid[r])
    local panelText = panelLines[r] or string.rep(" ", panelWidth)
    table.insert(rows, mapText .. " " .. panelText)
  end

  -- Footer.
  table.insert(rows, padRight(string.rep("-", width), width))
  local chargeText = chargePercent and string.format("%.0f%%", chargePercent * 100) or "?"
  table.insert(rows, padRight(string.format("Pos: (%d,%d)  Charge: %s", dronePos.x, dronePos.z, chargeText), width))

  return rows, placements, mapWidth
end

-- Blits the buffer to the real terminal, in color: the base text draws in
-- a dim default, then each placement (drone/apiary/storage/charger) gets
-- repainted in its own color from M.COLORS. Uses component.gpu directly
-- (not term) since precise per-cell color needs gpu.set/setForeground,
-- not term's cursor-based writer. Call this in a loop (see
-- bee_keeper_manager_run.lua) -- cheap enough to redraw every step.
function M.draw(sites, dronePos, extras, statusInfo, chargePercent, droneInventory, storageInventory)
  local gpu = require("component").gpu
  local width, height = gpu.getResolution()

  local rows, placements, mapWidth = M.renderBuffer(sites, dronePos, extras, statusInfo, chargePercent, width, height, droneInventory, storageInventory)

  gpu.setForeground(M.COLORS.default)
  gpu.fill(1, 1, width, height, " ")
  for i, row in ipairs(rows) do
    gpu.set(1, i, row)
  end

  -- Header/footer text, and the side panel (everything right of the map),
  -- read better bright than at the map's dim default -- only the map's
  -- "." background stays dim.
  gpu.setForeground(M.COLORS.text)
  gpu.set(1, 1, rows[1])
  gpu.set(1, #rows, rows[#rows])
  local panelCol = mapWidth + 2
  for i = 2, #rows - 1 do
    local panelText = rows[i]:sub(panelCol)
    if #panelText > 0 then
      gpu.set(panelCol, i, panelText)
    end
  end

  for _, p in ipairs(placements) do
    gpu.setForeground(M.COLORS[p.colorKey] or M.COLORS.default)
    gpu.set(p.col, p.row, p.char)
  end
end

return M
