--[[
  Tests for bee_keeper_status.lua (pure, no mocks needed) and
  bee_keeper_ui.lua's renderBuffer (pure layout/scaling/symbol logic --
  no term/gpu involved, so no mocks needed there either). M.draw itself
  isn't tested here since it's a thin, untestable-without-hardware wrapper
  around term/gpu -- see the module's own doc comment on that split.
--]]

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- ============================================================
-- bee_keeper_status.lua
-- ============================================================

do
  local Status = require("bee_keeper_status")
  check("status starts idle", Status.get().step == "idle")

  Status.setStep("Doing a thing")
  check("setStep updates step", Status.get().step == "Doing a thing")
  check("setStep appends to history", Status.get().history[#Status.get().history] == "Doing a thing")

  local changeCount = 0
  Status.onChange = function() changeCount = changeCount + 1 end
  Status.setStep("Another thing")
  check("onChange fires on every setStep", changeCount == 1)
  Status.onChange = nil

  for i = 1, 20 do Status.setStep("step " .. i) end
  check("history is capped at HISTORY_LIMIT", #Status.get().history == Status.HISTORY_LIMIT,
    "len=" .. #Status.get().history)
  check("history keeps the MOST RECENT entries, not the oldest",
    Status.get().history[#Status.get().history] == "step 20")
end

-- ============================================================
-- bee_keeper_ui.lua: renderBuffer
-- ============================================================

local UI = require("bee_keeper_ui")

do
  local sites = {
    { name = "site1", x = 0, z = 0, mode = "traitmax" },
    { name = "site2", x = 10, z = 0, mode = "species" },
    { name = "site3", x = 10, z = 10, mode = "mutation" },
  }
  local dronePos = { x = 5, z = 5 }
  local extras = { chargerPos = { x = -2, z = -2 }, storagePos = { x = 12, z = 12 } }
  local status = { step = "Flying to (10,10)", history = { "a", "b", "c" } }

  local rows, placements = UI.renderBuffer(sites, dronePos, extras, status, 0.75, 40, 16)

  check("renderBuffer returns exactly `height` rows", #rows == 16, "rows=" .. #rows)
  for i, row in ipairs(rows) do
    check("row " .. i .. " is exactly `width` chars", #row == 40, "len=" .. #row)
  end

  local joined = table.concat(rows, "\n")
  check("map contains a traitmax symbol", joined:find("T", 1, true) ~= nil)
  check("map contains a species symbol", joined:find("S", 1, true) ~= nil)
  check("map contains a mutation symbol", joined:find("M", 1, true) ~= nil)
  check("map contains the storage symbol", joined:find("%$") ~= nil)
  check("map contains the charger symbol", joined:find("C", 1, true) ~= nil)
  check("map contains the drone symbol", joined:find("@", 1, true) ~= nil)

  -- The specific ask: current action refreshes at the TOP, not buried
  -- somewhere in the middle/bottom.
  check("row 1 is the current step", rows[1]:find("Flying to %(10,10%)") ~= nil, rows[1])
  check("row 2 is a separator between the step and the grid", rows[2]:match("^%-+$") ~= nil, rows[2])

  check("footer shows position", rows[#rows]:find("Pos: %(5,5%)") ~= nil, rows[#rows])
  check("footer shows charge percent", rows[#rows]:find("75%%") ~= nil, rows[#rows])

  -- Coloring: drone, apiaries, and storage must each be independently
  -- colorable (the actual ask). All apiaries share ONE color regardless
  -- of mode -- per your call, traitmax/species/mutation sites still get
  -- different SYMBOLS (so you can tell modes apart by character) but not
  -- different colors.
  local byKey = {}
  local apiaryCount = 0
  for _, p in ipairs(placements) do
    byKey[p.colorKey] = p
    if p.colorKey == "apiary" then apiaryCount = apiaryCount + 1 end
  end
  check("all 3 sites are colored as plain apiaries, not per-mode", apiaryCount == 3, "apiaryCount=" .. apiaryCount)
  check("placements include storage", byKey.storage ~= nil)
  check("placements include charger", byKey.charger ~= nil)
  check("placements include the drone", byKey.drone ~= nil)

  check("drone, apiary, storage, and charger each have a distinct color",
    UI.COLORS.drone ~= UI.COLORS.apiary and UI.COLORS.apiary ~= UI.COLORS.storage
    and UI.COLORS.storage ~= UI.COLORS.charger and UI.COLORS.charger ~= UI.COLORS.drone)

  -- Each placement's (row,col) must actually match where that symbol
  -- landed in the text grid -- otherwise M.draw would color the wrong cell.
  for _, p in ipairs(placements) do
    local rowText = rows[p.row]
    check("placement for " .. p.colorKey .. " points at its own symbol in the text grid",
      rowText:sub(p.col, p.col) == p.char,
      string.format("row=%d col=%d expected=%s got=%s", p.row, p.col, p.char, rowText:sub(p.col, p.col)))
  end
end

-- ============================================================
-- Test: summarizeStack
-- ============================================================

do
  check("summarizeStack: nil slot", UI.summarizeStack(nil) == nil)
  check("summarizeStack: unanalyzed bee", UI.summarizeStack({ individual = { isAnalyzed = false } }) == "unanalyzed bee")
  check("summarizeStack: analyzed bee shows species name",
    UI.summarizeStack({ individual = { isAnalyzed = true, active = { species = { name = "Forest" } } } }) == "Forest")
  check("summarizeStack: analyzed bee with flat species string still works",
    UI.summarizeStack({ individual = { isAnalyzed = true, active = { species = "Forest" } } }) == "Forest")
  check("summarizeStack: non-bee item shows its name", UI.summarizeStack({ name = "forestry:honey_drop" }) == "forestry:honey_drop")
end

-- ============================================================
-- Test: cargo/storage panel appears in the side panel, next to the map
-- ============================================================

do
  local sites = { { name = "site1", x = 0, z = 0, mode = "traitmax" } }
  local dronePos = { x = 0, z = 0 }
  local droneInventory = {
    { slot = 2, stack = { individual = { isAnalyzed = true, active = { species = { name = "Forest" } } } } },
    { slot = 5, stack = { name = "forestry:honey_drop" } },
  }
  local storageInventory = {
    { slot = 1, stack = { individual = { isAnalyzed = true, active = { species = { name = "Meadows" } } } } },
  }

  local rows = UI.renderBuffer(sites, dronePos, {}, { step = "x" }, nil, 60, 18, droneInventory, storageInventory)
  local joined = table.concat(rows, "\n")

  check("panel shows the Cargo header", joined:find("Cargo:", 1, true) ~= nil)
  check("panel shows a cargo slot's species", joined:find("2: Forest", 1, true) ~= nil, joined)
  check("panel shows a non-bee cargo item by name", joined:find("5: forestry:honey_drop", 1, true) ~= nil)
  check("panel shows the Storage header", joined:find("Storage:", 1, true) ~= nil)
  check("panel shows a storage slot's species", joined:find("1: Meadows", 1, true) ~= nil, joined)
end

do
  -- nil storageInventory means "we don't know" (haven't visited it) --
  -- must not be confused with an empty chest.
  local rows = UI.renderBuffer({}, { x = 0, z = 0 }, {}, { step = "x" }, nil, 60, 18, {}, nil)
  local joined = table.concat(rows, "\n")
  check("unknown storage reads as 'not visited yet', not empty", joined:find("not visited yet", 1, true) ~= nil, joined)

  local rows2 = UI.renderBuffer({}, { x = 0, z = 0 }, {}, { step = "x" }, nil, 60, 18, {}, {})
  local joined2 = table.concat(rows2, "\n")
  check("a genuinely empty storage reads as '(empty)'", joined2:find("%(empty%)") ~= nil, joined2)
end

-- ============================================================
-- Test: per-apiary progress % in the side panel
-- ============================================================

do
  local sites = {
    { name = "apiary1", x = 0, z = 0, mode = "traitmax", progress = 0.75 },
    { name = "apiary2", x = 5, z = 5, mode = "traitmax", progress = 1.0 },
    { name = "apiary3", x = 9, z = 1, mode = "traitmax" }, -- never visited
  }
  local rows = UI.renderBuffer(sites, { x = 0, z = 0 }, {}, { step = "x" }, nil, 70, 20, {}, {})
  local joined = table.concat(rows, "\n")

  check("panel shows the Apiaries header", joined:find("Apiaries:", 1, true) ~= nil)
  check("panel shows a partial progress percent", joined:find("75%%") ~= nil, joined)
  check("panel shows 100%% for a fully purebred apiary", joined:find("100%%") ~= nil)
  check("panel names each apiary", joined:find("apiary1", 1, true) and joined:find("apiary3", 1, true) ~= nil)

  -- An unvisited apiary must read as unknown, NOT as 0% -- progress is a
  -- last-known cached value, so "no reading yet" and "genuinely 0%" are
  -- different states.
  check("unvisited apiary shows '--' rather than 0%", joined:find("--", 1, true) ~= nil, joined)
  check("unvisited apiary does not falsely report 0%", joined:find("0%%%s+apiary3") == nil)
end

-- ============================================================
-- Test: cargo is capped so storage stays visible
-- ============================================================

do
  local bigCargo = {}
  for i = 1, 15 do
    table.insert(bigCargo, { slot = i, stack = { individual = { isAnalyzed = true, active = { species = { name = "Forest" } } } } })
  end
  local rows = UI.renderBuffer({}, { x = 0, z = 0 }, {}, { step = "x" }, nil, 70, 24, bigCargo, {})
  local joined = table.concat(rows, "\n")

  check("cargo list is truncated", joined:find("%.%.%.%+%d+ more") ~= nil, joined)
  check("storage section survives a full cargo hold", joined:find("Storage:", 1, true) ~= nil)
end

-- ============================================================
-- Test: drone always wins symbol placement when co-located with a site
-- ============================================================

do
  local sites = { { name = "site1", x = 3, z = 3, mode = "traitmax" } }
  local dronePos = { x = 3, z = 3 } -- exactly on top of the site
  local rows, placements = UI.renderBuffer(sites, dronePos, {}, { step = "x", history = {} }, nil, 20, 10)
  local joined = table.concat(rows, "\n")
  check("drone symbol overrides an overlapping site symbol", joined:find("@", 1, true) ~= nil)

  -- M.draw paints placements in order, so the LAST one for a given cell
  -- is what actually ends up visible/colored -- must be the drone, not
  -- the site it's standing on, or the drone would render in traitmax's
  -- color instead of its own.
  check("drone is placed last so it also wins the color, not just the character",
    placements[#placements].colorKey == "drone")
end

-- ============================================================
-- Test: the map is ONE CHARACTER PER BLOCK, not stretched to fill the
-- reserved map area -- a small real-world area (here, 4x6) must render
-- as a small patch of dots with blank whitespace around it, not a
-- screen-sized grid of periods (the actual real-hardware bug reported:
-- a 4x6 scanned area rendered as a giant dot-filled map).
-- ============================================================

do
  local sites = {
    { name = "site1", x = 0, z = 0, mode = "traitmax" },
    { name = "site2", x = 3, z = 5, mode = "traitmax" },
  }
  local dronePos = { x = 1, z = 1 }
  -- width=60 -> mapWidth = floor(60*0.55) = 33, contentHeight = 20-4 = 16
  -- -- both FAR bigger than the real 4x6 (x:0-3, z:0-5) area.
  local rows = UI.renderBuffer(sites, dronePos, {}, { step = "x", history = {} }, nil, 60, 20)

  local dotCount = 0
  for _, row in ipairs(rows) do
    for _ in row:gmatch("%.") do dotCount = dotCount + 1 end
  end
  -- The real area is 4 wide (x: 0..3) x 6 tall (z: 0..5) = 24 cells, minus
  -- however many are covered by symbols instead of ".". Anything even
  -- close to the full 33x16 map area (528 cells) means it's still
  -- stretching instead of rendering 1 block = 1 character.
  check("a small real area renders as a small patch of dots, not a screen-filling grid",
    dotCount <= 24, "dotCount=" .. dotCount)

  -- The reserved map area is still 33 wide -- just mostly blank space
  -- past the real area, not periods. Only checking actual map rows (not
  -- the STEP header/separator/footer rows, which have unrelated content
  -- at that column).
  local mapWidth = 33
  local blankFound = false
  for i = 3, #rows - 2 do
    if rows[i]:sub(mapWidth, mapWidth) == " " then blankFound = true end
  end
  check("space beyond the real area is blank whitespace, not more dots", blankFound)
end

-- ============================================================
-- Test: degenerate layouts (single site, or drone/sites all at one point)
-- don't error and still place a mark somewhere sensible
-- ============================================================

do
  local ok, rows = pcall(UI.renderBuffer, {}, { x = 0, z = 0 }, {}, { step = "idle", history = {} }, nil, 30, 12)
  check("renderBuffer handles zero sites without erroring", ok, tostring(rows))
  if ok then
    check("still produces the right row count with no sites", #rows == 12)
  end
end

do
  local sites = { { name = "only", x = 7, z = 7, mode = "traitmax" } }
  local ok, rows = pcall(UI.renderBuffer, sites, { x = 7, z = 7 }, {}, { step = "idle", history = {} }, nil, 30, 12)
  check("renderBuffer handles a single-point bounding box without erroring", ok, tostring(rows))
end

-- ============================================================
-- Test: missing charge percent renders as "?" rather than erroring
-- ============================================================

do
  local rows = UI.renderBuffer({}, { x = 0, z = 0 }, {}, { step = "idle", history = {} }, nil, 30, 12)
  local joined = table.concat(rows, "\n")
  check("nil chargePercent shows as '?' not a crash", joined:find("Charge: %?") ~= nil, joined)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
