--[[
  Scenario Sim -- exact block layout, detailed step-through validation
  --------------------------------------------------------------------
  Runs the REAL bee_keeper_manager against bee_keeper_sim's fake world, but
  seeded to a SPECIFIC physical layout so its every action can be single-stepped
  and compared, action-for-action, against the same setup in Minecraft (run the
  real robot with `bee_keeper_manager_run step`).

  The user's block grid (x = column, z = row; their letters, kept verbatim):

      AA  X        A = ApChest (bee storage)   D = Drawer (honey)
      DAY          C = Charger                 Y = Apiary
       A  Y        X = Trash
      C

    ApChests : (0,0) (1,0) (1,1) (1,2)   -- (0,0) is store #1, the seeded one
    Drawer   : (0,1)      Trash: (4,0)     Charger: (0,3)
    Apiaries : (2,1) (4,2)
    Robot    : starts on the charger (0,3), 32 cargo slots, empty

  Seeded top-left ApChest (0,0): 5 pristine Meadows princesses, 5 pristine Forest
  princesses, a stack of 64 Forest drones, a stack of 64 Meadows drones. Every
  other container empty. Drawer holds honey. (Base alleles only -- Forest/Meadows
  are the wild starting stock; Forest + Meadows -> Common is the first mutation.)

  Usage:
    lua bee_keeper_scenario_sim.lua            -- step mode (prompt each action)
    lua bee_keeper_scenario_sim.lua run 5      -- auto-run 5 cycles (no prompts)
    lua bee_keeper_scenario_sim.lua 30         -- step mode, up to 30 cycles

  CONTAINER VIEW: after every action it prints the detailed contents of every
  CONTAINER (the 4 ApChests + the 2 apiaries) plus the robot's cargo -- slot
  numbers, item kind, species (active/inactive) and key alleles -- so you can eye
  it against the real chests. (Drawer + trash are intentionally not shown.)
--]]

local args = { ... }
local autoRun = false
local cycles = 40
for _, a in ipairs(args) do
  if a == "run" then autoRun = true
  elseif tonumber(a) then cycles = tonumber(a) end
end

-- ============================================================
-- 1. Config: the exact layout above.
-- ============================================================
local config = require("bee_keeper_manager_config")

config.honeySlot = 1
config.workingSlots = {}
for s = 2, 32 do config.workingSlots[#config.workingSlots + 1] = s end -- 31 usable + honey slot 1 = 32

-- Nav.setHome ALWAYS makes the robot's START its origin (0,0), and the robot
-- starts ON THE CHARGER -- so every position must be expressed RELATIVE to the
-- charger. The user's grid has the charger at (0,3); we subtract that offset so
-- charger = (0,0) (Nav origin = world.drone start), keeping the exact relative
-- layout. (This is also how real hardware sees it: coords are relative to
-- wherever setHome was called, i.e. where the robot was placed.)
--   grid (x,z)  ->  Nav-relative (x, z-3)
local AP_CHESTS = { { x = 0, z = -3 }, { x = 1, z = -3 }, { x = 1, z = -2 }, { x = 1, z = -1 } }
config.storagePositions = AP_CHESTS
config.storagePos = AP_CHESTS[1]
config.honeyStoragePos = { x = 0, z = -2 } -- drawer  (grid 0,1)
config.trashPos = { x = 4, z = -3 }        -- grid 4,0
config.chargerPos = { x = 0, z = 0 }       -- grid 0,3 == robot start == Nav origin

local sites = {
  { name = "apiary1", x = 2, z = -2, mode = "mutation", targetSpecies = "Common" }, -- grid 2,1
  { name = "apiary2", x = 4, z = -1, mode = "mutation", targetSpecies = "Common" }, -- grid 4,2
}
config.sites = sites
config.program = nil -- single explicit goal (Common), not the traitmax->rainbow->perfect program

-- ============================================================
-- 2. Install the fake world, then RE-SEED to the exact layout.
-- ============================================================
local Sim = require("bee_keeper_sim")
Sim.install(config, sites, {
  cargoSize = 32,
  storageSize = 125,           -- apiarist chests
  storageSizes = { 125, 125, 125, 125 },
  honeyDrawerStock = 64,
})
local world = Sim.world
local traitList = world.traitList

-- Real GTNH mutation graph + species templates, so Forest + Meadows -> Common
-- (and the rest of the real tree) behaves exactly as in-game.
local M = require("bee_keeper_manager")
local graph = select(1, M.loadMutationGraph(config))
if graph then
  -- Rebuild the sim's symmetric pair index off the REAL graph (newWorld only did
  -- so if opts.mutationGraph was passed; we loaded it after install).
  world.mutationPairIndex = {}
  local function addPair(p, d, result, chance, conditions)
    for _, key in ipairs({ p .. "|" .. d, d .. "|" .. p }) do
      world.mutationPairIndex[key] = world.mutationPairIndex[key] or {}
      table.insert(world.mutationPairIndex[key], { result = result, chance = chance or 0, conditions = conditions or {} })
    end
  end
  for result, recipes in pairs(graph.byResult) do
    for _, r in ipairs(recipes) do addPair(r.princess, r.drone, result, r.chance, r.conditions) end
  end
end
local templates = select(1, M.loadTemplates(config))
world.templates = templates

-- Wipe the demo seeding install() did (cargo bees, storage bees, honey backup).
world.drone.inventory = {}
world.storage = {} -- store #1 (top-left chest (0,0))
for _, s in ipairs(world.storages) do
  if not s.primary and s.slots then s.slots = {} end -- clear the other chests (drawer keeps its honey)
end

-- Robot starts empty, on the charger (= Nav origin (0,0), the world.drone
-- default from install -- do NOT reposition it, or Nav's dead-reckoning desyncs
-- from world.drone and every gotoXZ lands at the wrong block). Just top it up.
world.drone.x = 0
world.drone.z = 0
world.drone.facing = 1
world.drone.energy = 1.0
world.drone._selected = nil

-- Build one analyzed, pristine bee of `species` in the given role.
local function makeBee(species, kind, size)
  local raw = Sim.makeTemplateRaw(traitList, species, templates)
  raw._natural = true -- pristine (princess lines that never degrade)
  local stack = Sim.toStack(raw, kind, true) -- analyzed
  stack.size = size or 1
  return stack
end

-- Seed the top-left ApChest (store #1 = world.storage), in the user's order.
do
  local slot = 1
  for _ = 1, 5 do world.storage[slot] = makeBee("Meadows", "princess", 1); slot = slot + 1 end
  for _ = 1, 5 do world.storage[slot] = makeBee("Forest", "princess", 1); slot = slot + 1 end
  world.storage[slot] = makeBee("Forest", "drone", 64); slot = slot + 1
  world.storage[slot] = makeBee("Meadows", "drone", 64); slot = slot + 1
end

-- ============================================================
-- 3. Detailed CONTAINER + cargo view.
-- ============================================================
local Nav = require("bee_keeper_nav")
local Status = require("bee_keeper_status")
Nav.setHome(70)

local ALLELE_COLS = { "fertility", "speed", "lifespan" } -- compact allele summary

local function kindOf(stack)
  if not stack or not stack.name then return "?" end
  local n = stack.name:lower()
  if n:find("queen") then return "Queen" end
  if n:find("princess") then return "Princess" end
  if n:find("drone") then return "Drone" end
  if n:find("honey") or n:find("honeydew") then return "Honey" end
  return stack.name
end

-- One compact line describing a slot's stack: "s3  Drone x64  Forest/Meadows  fert 3/2 spd .3/.3 life 30/40"
local function describeStack(slotLabel, stack)
  if not stack then return string.format("  %-4s (empty)", slotLabel) end
  local ind = stack.individual
  if not ind or not ind.active then
    return string.format("  %-4s %s x%d", slotLabel, kindOf(stack), stack.size or 1)
  end
  local sp = string.format("%s/%s",
    ind.active.species and ind.active.species.name or "?",
    ind.inactive.species and ind.inactive.species.name or "?")
  local alleles = {}
  for _, t in ipairs(ALLELE_COLS) do
    local a, b = ind.active[t], ind.inactive[t]
    if a ~= nil then
      local short = ({ fertility = "fert", speed = "spd", lifespan = "life" })[t] or t
      alleles[#alleles + 1] = string.format("%s %s/%s", short, tostring(a), tostring(b))
    end
  end
  local flags = ind.isAnalyzed and "" or " (UNANALYZED)"
  return string.format("  %-4s %-8s x%-2d %-18s %s%s",
    slotLabel, kindOf(stack), stack.size or 1, sp, table.concat(alleles, "  "), flags)
end

-- Live view of a bee-storage chest by position (reads world.storages).
local function chestSlots(pos)
  for _, s in ipairs(world.storages) do
    if s.x == pos.x and s.z == pos.z then
      if s.primary then return world.storage, world.storageSize end
      return s.slots, s.size
    end
  end
  return {}, 0
end

local function printContainers()
  local out = {}
  local function line(t) out[#out + 1] = t end

  line("")
  line(string.rep("=", 72))
  line(string.format("STEP: %s   |   robot @ (%d,%d) energy %.0f%% sel=%s",
    Status.get().step, world.drone.x, world.drone.z, (world.drone.energy or 0) * 100,
    tostring(world.drone._selected)))
  line(string.rep("=", 72))

  -- ApChests (containers)
  for i, pos in ipairs(AP_CHESTS) do
    local slots = chestSlots(pos)
    local n = 0; for _ in pairs(slots) do n = n + 1 end
    line(string.format("ApChest #%d (%d,%d)%s -- %d occupied", i, pos.x, pos.z,
      i == 1 and " [store 1]" or "", n))
    local keys = {}
    for k in pairs(slots) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do line(describeStack("s" .. k, slots[k])) end
    if n == 0 then line("  (empty)") end
  end

  -- Apiaries (containers): queen (1), drone (2), output (3+)
  for _, s in ipairs(sites) do
    local a = world.apiaries[s.x .. ":" .. s.z]
    line(string.format("Apiary %s (%d,%d) -- workTicks %d/%d", s.name, s.x, s.z,
      a and a.workTicks or 0, a and a.workNeeded or 0))
    line(describeStack("Q", a and a.princessRaw and Sim.toStack(a.princessRaw, "princess") or nil))
    line(describeStack("D", a and a.droneRaw and Sim.toStack(a.droneRaw, "drone") or nil))
    if a and a.products then
      for pslot, st in pairs(a.products) do line(describeStack("out" .. pslot, st)) end
    end
  end

  -- Robot cargo
  line(string.format("ROBOT CARGO (32 slots, honeySlot=%d)", config.honeySlot))
  local any = false
  local cargoSlots = { config.honeySlot }
  for _, s in ipairs(config.workingSlots) do cargoSlots[#cargoSlots + 1] = s end
  for _, slot in ipairs(cargoSlots) do
    local st = world.drone.inventory[slot]
    if st then line(describeStack("s" .. slot, st)); any = true end
  end
  if not any then line("  (empty)") end

  for _, l in ipairs(out) do print(l) end
end

-- ============================================================
-- 4. Step control: pause after each action (task boundary), render, prompt.
-- ============================================================
local stepControl = autoRun and "running" or "paused"
local function prompt()
  if stepControl ~= "paused" then return end
  while true do
    io.write("\n[step] (s)tep / (r)esume / (q)uit > ")
    local cmd = (io.read() or "q"):lower()
    if cmd == "" or cmd == "s" then return
    elseif cmd == "r" then stepControl = "running"; return
    elseif cmd == "q" then os.exit(0)
    else print("?") end
  end
end

-- A cheap signature of every CONTAINER's contents (chests + apiary slots +
-- cargo) -- so the detailed view is re-rendered (and, in step mode, prompts)
-- ONLY when a container actually changed, i.e. "persists until the next
-- container action" per spec. Pure movement between actions doesn't redraw.
local function containersSignature()
  local parts = {}
  local function slotSig(slot, st)
    parts[#parts + 1] = tostring(slot) .. ":" .. (st and ((st._uid or st.name or "?") .. "x" .. (st.size or 1)) or "-")
  end
  for _, pos in ipairs(AP_CHESTS) do
    local slots = chestSlots(pos)
    parts[#parts + 1] = "|C" .. pos.x .. "," .. pos.z
    local keys = {}; for k in pairs(slots) do keys[#keys + 1] = k end; table.sort(keys)
    for _, k in ipairs(keys) do slotSig(k, slots[k]) end
  end
  for _, s in ipairs(sites) do
    local a = world.apiaries[s.x .. ":" .. s.z]
    parts[#parts + 1] = "|A" .. s.name
    slotSig("Q", a and a.princessRaw and { _uid = a.princessRaw._uid } or nil)
    slotSig("D", a and a.droneRaw and { _uid = a.droneRaw._uid } or nil)
    for pslot, st in pairs(a and a.products or {}) do slotSig("o" .. pslot, st) end
  end
  parts[#parts + 1] = "|R"
  local cargo = { config.honeySlot }
  for _, s in ipairs(config.workingSlots) do cargo[#cargo + 1] = s end
  for _, slot in ipairs(cargo) do slotSig(slot, world.drone.inventory[slot]) end
  return table.concat(parts)
end

local lastSig = nil
Status.onChange = function()
  local sig = containersSignature()
  if sig == lastSig then return end -- no container change -> view persists, no prompt
  lastSig = sig
  printContainers()
  prompt()
end

print("Scenario sim: 4 ApChests, 2 apiaries, drawer+trash+charger; seeding Forest/Meadows base stock.")
print(string.format("Goal: mutation -> Common at both apiaries. %s, up to %d cycles.\n",
  autoRun and "auto-run" or "STEP MODE", cycles))
printContainers()
prompt()

for cycle = 1, cycles do
  print(string.format("\n########## CYCLE %d ##########", cycle))
  local log = M.runCycle(config)
  for _, l in ipairs(log) do print("  " .. l) end
end

print("\nDone.")
