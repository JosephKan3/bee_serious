--[[
  Bee Keeper Sim
  ---------------
  A real, runnable local simulator -- not a per-test mock. Backs the exact
  same "component"/"sides"/"computer"/"term" interfaces the production
  code already talks to (that's the whole point of the decoupling: nothing
  in bee_keeper_manager.lua/bee_keeper_nav.lua/bee_keeper_ui.lua changes at
  all to run against this instead of real hardware), with a coherent fake
  world: a Robot agent (position/facing/energy/inventory, exposing
  component.robot -- see bee_keeper_nav.lua's header on why this is a
  Robot and not a Drone), apiaries that actually breed using
  bee_breeding.lua's real genetics (not scripted results), and a storage
  chest.

  PACING: per your call, actions take ~1 real second when running locally,
  and NOTHING here touches the real drone path at all -- when
  bee_keeper_manager_run.lua runs for real in Minecraft, it uses the real
  "component" library and genuinely waits on real hardware/game ticks, the
  same as it always did. This module is purely additive; Sim.install()
  only ever runs when something explicitly requires this file first.
--]]

local BB = require("bee_breeding")
local Cfg = require("bee_trait_config")

local M = {}

-- ============================================================
-- Real-time pacing: ~1 second per action, hooked onto Status.onChange
-- (fires at every meaningful action boundary already instrumented in
-- bee_keeper_manager.lua/bee_keeper_nav.lua -- see those files). A crude
-- os.clock() busy-wait, since stock Lua has no os.sleep to build on.
-- ============================================================

local function realSleep(seconds)
  local target = os.clock() + seconds
  while os.clock() < target do end
end
M.realSleep = realSleep

M.secondsPerAction = 1

-- Separate, much faster pace for individual block movement (see
-- Nav.onStep in bee_keeper_local_sim_run.lua) -- a multi-block walk
-- shown one redraw per block at the full secondsPerAction pace would
-- take forever to watch for anything but a short hop.
M.secondsPerStep = 0.1

-- ============================================================
-- Terminal fitting
-- ============================================================

-- Best-effort real terminal size. The dashboard draws with absolute
-- cursor addressing, so a frame WIDER than the window is what actually
-- cuts the top off: every over-wide row wraps into two screen lines,
-- roughly doubling the frame's height until it overflows and scrolls.
-- Tries $COLUMNS/$LINES, then `tput`, then the given fallbacks.
--
-- These fallback clamps assume auto-detected sizing (a real terminal is
-- rarely usefully smaller than this) -- an EXPLICIT request for a smaller
-- grid should not be silently bumped back up to them; see
-- M.resolveTermSize below, which is what Sim.install actually calls.
function M.detectTermSize(defaultW, defaultH)
  local w = tonumber(os.getenv("COLUMNS"))
  local h = tonumber(os.getenv("LINES"))

  local function tput(what)
    local ok, pipe = pcall(io.popen, "tput " .. what .. " 2>/dev/null")
    if not ok or not pipe then return nil end
    local value = tonumber(pipe:read("*l"))
    pipe:close()
    return value
  end

  if not w then w = tput("cols") end
  if not h then h = tput("lines") end

  w = w or defaultW or 60
  h = h or defaultH or 18

  -- Keep one row spare so the shell prompt has somewhere to land on exit
  -- without pushing the frame up a line.
  h = h - 1

  -- Clamp: renderBuffer needs room for its header/footer plus a usable
  -- map, and an enormous frame just wastes redraw time.
  w = math.max(40, math.min(w, 200))
  h = math.max(12, math.min(h, 60))
  return w, h
end

-- Absolute floor below which bee_keeper_ui.lua's layout stops making
-- sense (STATUS_ROWS=4 needs at least a couple of those rows to actually
-- be map, and the footer text "Pos: (-99,-99)  Charge: 100%" needs room).
M.MIN_WIDTH = 24
M.MIN_HEIGHT = 7

-- Grid size to actually use: if BOTH width and height are explicitly
-- given (e.g. from a "WxH" CLI arg), honor them as-is -- just clamped to
-- the sane minimum above, not bumped up to auto-detect's larger fallback
-- floor. Otherwise falls back to auto-detection.
function M.resolveTermSize(explicitW, explicitH)
  if explicitW and explicitH then
    return math.max(M.MIN_WIDTH, explicitW), math.max(M.MIN_HEIGHT, explicitH)
  end
  return M.detectTermSize(explicitW, explicitH)
end

-- Disables auto-wrap -- a row exactly as wide as the window, or a write
-- landing on the bottom-right cell, would otherwise auto-advance and
-- scroll the whole frame up a line -- and hides the cursor so it stops
-- flickering across the frame on every redraw.
function M.beginScreen()
  io.write("\27[?7l\27[?25l")
end

-- Puts auto-wrap and the cursor back. Call on normal exit; if the sim is
-- Ctrl+C'd instead, run `printf '\27[?7h\27[?25h'` (or just open a new
-- window) to restore them.
function M.endScreen()
  io.write("\27[?7h\27[?25h\27[0m\n")
end

-- ============================================================
-- Genetics: a small raw-value Mendelian crosser, operating on the SAME
-- raw Forestry-shaped values bee_trait_config.lua expects (numbers,
-- strings, booleans, {name=..} species tables) -- not the abstracted
-- good/bad representation bee_breeding.lua works with internally. This
-- means simulated offspring show real allele diversity (fertility
-- actually varies 1-4, species actually segregates, etc.), not just a
-- binary good/bad flag.
-- ============================================================

local function pickRawAllele(alleles)
  if math.random() < 0.5 then return alleles.active end
  return alleles.inactive
end

-- parentA/parentB: { [trait] = { active = rawValue, inactive = rawValue } }
local function crossRaw(traitList, parentA, parentB)
  local child = {}
  for _, trait in ipairs(traitList) do
    child[trait] = {
      active = pickRawAllele(parentA[trait]),
      inactive = pickRawAllele(parentB[trait]),
    }
  end
  return child
end

-- Builds a raw genotype where every trait is set to its "good" target
-- (from bee_trait_config.lua) or, for traits marked "any", a plausible
-- default. targetSpeciesName seeds the species locus.
local function makeGoodRaw(traitList, speciesName)
  local g = {}
  for _, trait in ipairs(traitList) do
    if trait == "species" then
      local sp = { name = speciesName, uid = "sim." .. speciesName:lower(), humidity = "Normal", temperature = "Normal" }
      g[trait] = { active = sp, inactive = sp }
    else
      local spec = Cfg.targets[trait]
      local value = (spec and spec.target) or 0
      g[trait] = { active = value, inactive = value }
    end
  end
  return g
end

-- Builds a deliberately mediocre/starting raw genotype -- something with
-- real gaps to fix, not already-perfect.
local function makeStartingRaw(traitList, speciesName)
  local mediocre = {
    fertility = 1, speed = 0.6, lifespan = 50, flowering = 10,
    flowerProvider = "flowersDirt", temperatureTolerance = "NONE",
    humidityTolerance = "NONE", nocturnal = false, tolerantFlyer = false,
    caveDwelling = false, effect = "forestry:none", territory = { 9, 6, 9 },
  }
  local g = {}
  for _, trait in ipairs(traitList) do
    if trait == "species" then
      local sp = { name = speciesName, uid = "sim." .. speciesName:lower(), humidity = "Normal", temperature = "Normal" }
      g[trait] = { active = sp, inactive = sp }
    else
      local value = mediocre[trait]
      if value == nil then value = 0 end
      g[trait] = { active = value, inactive = value }
    end
  end
  return g
end

-- Converts a raw genotype (active/inactive per trait) into the
-- stack.individual shape bee_keeper_manager.lua's readIndividual expects.
-- Skips "_uid" -- toStack (below) caches a per-individual id directly on
-- the raw genotype table, which isn't a trait and doesn't have
-- .active/.inactive fields.
local function toIndividual(rawGenotype)
  local active, inactive = {}, {}
  for trait, alleles in pairs(rawGenotype) do
    if trait ~= "_uid" then
      active[trait] = alleles.active
      inactive[trait] = alleles.inactive
    end
  end
  return { active = active, inactive = inactive, isAnalyzed = true }
end
-- Verbose-mode debugging aid: a stable, unique ID per actual individual
-- bee (not per stack-merge, not re-assigned every time the SAME bee is
-- re-read) -- lets a verbose inventory dump distinguish "this exact
-- drone" from another that just happens to share its genotype. Cached
-- directly on the RAW genotype table (rawGenotype._uid) the first time
-- it's ever converted to a stack, so repeated peeks (e.g. re-reading an
-- apiary's queen slot every cycle) return the SAME id instead of a fresh
-- one each time.
local nextBeeUid = 1
local function nextUid()
  local id = nextBeeUid
  nextBeeUid = nextBeeUid + 1
  return id
end

-- kind ("princess"/"drone"/nil) picks a real Forestry-style item name --
-- bee_keeper_manager.lua's findPrincessCandidate matches on item name
-- (case-insensitive "princess"/"queen"), so a generic name would make
-- this sim unable to ever exercise that code path at all.
local function toStack(rawGenotype, kind)
  if rawGenotype._uid == nil then rawGenotype._uid = nextUid() end
  local name = "forestry:bee"
  if kind == "princess" then name = "Forestry:beePrincessGE"
  elseif kind == "drone" then name = "Forestry:beeDroneGE" end
  return { name = name, size = 1, maxSize = 64, individual = toIndividual(rawGenotype), _uid = rawGenotype._uid }
end

-- Inverse of toIndividual -- extracts a raw genotype (active/inactive per
-- trait) back out of an individual table. Used when the production code
-- swaps a stack from cargo into an apiary slot. uid, if given (the
-- source STACK's _uid, not the individual's -- individuals don't carry
-- one), is threaded through so the same bee keeps the same id across the
-- cargo<->apiary round trip instead of minting a new one.
local function rawFromIndividual(individual, uid)
  local g = { _uid = uid }
  for trait, activeValue in pairs(individual.active) do
    g[trait] = { active = activeValue, inactive = individual.inactive[trait] }
  end
  return g
end

-- Real per-slot stack cap for anything simulated here (bees, combs,
-- honey alike) -- per your spec: same type stacks to 64, otherwise
-- occupies a separate slot.
local MAX_STACK = 64

-- Whether two raw item stacks would actually merge in a real inventory
-- slot: same item name, and if it's an analyzed bee, an EXACT genotype
-- match (mirrors bee_keeper_manager.lua's own stacksMatch -- duplicated
-- here since that's a private local there, not exported, and this sim
-- needs the identical rule to behave the same way real hardware does).
local function stacksMatch(a, b)
  if not a or not b or a.name ~= b.name then return false end
  local ai, bi = a.individual, b.individual
  if not ai and not bi then return true end
  if not (ai and bi) then return false end
  if ai.isAnalyzed ~= bi.isAnalyzed then return false end

  local function valuesEqual(x, y)
    if type(x) == "table" and type(y) == "table" then
      return x.name == y.name and x.uid == y.uid
    end
    return x == y
  end

  for trait, v in pairs(ai.active or {}) do
    if not valuesEqual(v, bi.active and bi.active[trait]) then return false end
  end
  for trait, v in pairs(ai.inactive or {}) do
    if not valuesEqual(v, bi.inactive and bi.inactive[trait]) then return false end
  end
  for trait in pairs(bi.active or {}) do
    if ai.active == nil or ai.active[trait] == nil then return false end
  end
  return true
end

local function isPrincessOrQueenStack(stack)
  if not stack or not stack.name then return false end
  local lower = stack.name:lower()
  return lower:find("princess") ~= nil or lower:find("queen") ~= nil
end

local function isDroneStack(stack)
  if not stack or not stack.name then return false end
  return stack.name:lower():find("drone") ~= nil
end

-- Shallow-copies a stack's fields into a brand-new table -- used whenever
-- a NEW stack needs to exist independently of its source (so mutating
-- the copy's .size later doesn't also change the original).
local function cloneStack(stack, size)
  local copy = {}
  for k, v in pairs(stack) do copy[k] = v end
  copy.size = size or stack.size or 1
  copy.maxSize = MAX_STACK
  return copy
end

-- Deposits `count` units of `incoming` into container[slot]: merges into
-- a matching, not-yet-full existing stack there, or creates a fresh one
-- if the slot's empty. Returns how many actually fit (0 if the slot
-- holds something incompatible, or is already full). Doesn't touch the
-- source at all -- callers are responsible for removing what actually
-- moved.
local function depositInto(container, slot, incoming, count)
  count = count or (incoming.size or 1)
  local existing = container[slot]
  if existing == nil then
    local moved = math.min(count, MAX_STACK)
    container[slot] = cloneStack(incoming, moved)
    return moved
  end
  if not stacksMatch(existing, incoming) then return 0 end
  local room = MAX_STACK - (existing.size or 1)
  local moved = math.min(count, room)
  if moved > 0 then existing.size = (existing.size or 1) + moved end
  return moved
end

M.crossRaw = crossRaw
M.makeGoodRaw = makeGoodRaw
M.makeStartingRaw = makeStartingRaw

-- ============================================================
-- World
-- ============================================================

function M.newWorld(config, sites)
  local traitList = Cfg.activeTraits()
  table.insert(traitList, "species")

  local world = {
    traitList = traitList,
    drone = {
      x = 0, z = 0,
      facing = 1, -- internal convention: 1=+Z, 2=+X, 3=-Z, 4=-X (matches bee_keeper_nav.lua)
      energy = 0.9,
      inventory = {},
    },
    apiaries = {}, -- key "x:z" -> { princessRaw, droneRaw, workTicks, workNeeded }
    storage = {},
    mutationRecipes = {
      -- A generous chance so a local demo run actually shows a mutation
      -- succeed within a reasonable number of cycles.
      ["NewBee"] = {
        { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 50 },
      },
    },
  }

  -- Seed traitmax/species sites with a mediocre starting princess so
  -- there's real work to do (an empty apiary would just report
  -- no_princess_at_site forever). Mutation sites start genuinely empty --
  -- runMutationSite sources its own pair from cargo and swaps both in, so
  -- pre-seeding a princess there would just get immediately swapped back
  -- out on the first attempt.
  for _, s in ipairs(sites) do
    if s.mode == "mutation" then
      world.apiaries[s.x .. ":" .. s.z] = { princessRaw = nil, droneRaw = nil, workTicks = 0, workNeeded = 2 }
    else
      local speciesName = s.mode == "species" and (s.targetSpecies or "Forest") or "Forest"
      world.apiaries[s.x .. ":" .. s.z] = {
        princessRaw = makeStartingRaw(traitList, speciesName),
        droneRaw = nil,
        workTicks = 0,
        workNeeded = 2,
      }
    end
  end

  -- Seed cargo: a couple of strong candidate drones, a couple of weak
  -- ones, honey, and (for mutation/species demo sites) whatever species
  -- each of those specifically needs. Iterates config.workingSlots (not a
  -- blind 1,2,3.. counter) and skips config.honeySlot, so seeding can't
  -- silently clobber the honey slot or land somewhere outside the pool
  -- bee_keeper_manager.lua actually looks at.
  local nextWorkingSlotIndex = 1
  local function put(rawGenotype, kind)
    while config.workingSlots[nextWorkingSlotIndex] == config.honeySlot do
      nextWorkingSlotIndex = nextWorkingSlotIndex + 1
    end
    local slot = config.workingSlots[nextWorkingSlotIndex]
    nextWorkingSlotIndex = nextWorkingSlotIndex + 1
    world.drone.inventory[slot] = toStack(rawGenotype, kind or "drone")
  end

  put(makeGoodRaw(traitList, "Forest"))
  put(makeStartingRaw(traitList, "Forest"))
  put(makeGoodRaw(traitList, "Forest"))

  for _, s in ipairs(sites) do
    if s.mode == "mutation" then
      -- A real mutation pair needs ONE princess/queen + ONE drone
      -- (Forestry doesn't care which named species ends up on which
      -- side) -- seeding two drones here would make every mutation
      -- attempt fail with swap_queen_failed, since nothing in cargo
      -- would actually be a princess.
      put(makeStartingRaw(traitList, "Forest"), "princess")
      put(makeStartingRaw(traitList, "Meadows"), "drone")
    elseif s.mode == "species" and s.targetSpecies then
      put(makeGoodRaw(traitList, s.targetSpecies))
    end
  end

  world.drone.inventory[config.honeySlot] = { name = "forestry:honey_drop", size = 64, maxSize = 64 }

  return world
end

-- ============================================================
-- Fake hardware, backed by the world above
-- ============================================================

-- opts.cargoSize / opts.storageSize: per your spec, cargo defaults to 16
-- and storage to 27, but both need to work with ANY configured size --
-- trash is always exactly 1 slot, and an apiary is always exactly 12
-- (1 princess + 1 drone + 3 frames, unused/unmodeled + 7 output), none
-- of which are configurable since those are fixed real-world facts, not
-- something a config file changes.
function M.install(config, sites, opts)
  opts = opts or {}
  local world = M.newWorld(config, sites)
  world.cargoSize = opts.cargoSize or 16
  world.storageSize = opts.storageSize or 27

  local function apiaryAt(x, z) return world.apiaries[x .. ":" .. z] end
  local function atPos(px, pz) return px ~= nil and world.drone.x == px and world.drone.z == pz end
  local function atStorage() return config.storagePos and atPos(config.storagePos.x, config.storagePos.z) end
  local function atTrash() return config.trashPos and atPos(config.trashPos.x, config.trashPos.z) end

  -- Apiary slot layout (always 12 total): 1=princess, 2=drone (each ONLY
  -- ever holding their own type -- see swapQueen/swapDrone below), 3-5=
  -- frames (not modeled -- always empty), 6-12=output (7 slots, general
  -- product: combs, drone offspring, the replacement princess, all
  -- stacking to 64 by exact match like anything else here).
  local APIARY_SIZE = 12
  local FRAME_SLOTS = { 3, 4, 5 }
  local FIRST_OUTPUT_SLOT = 6
  local function isFrameSlot(slot)
    for _, s in ipairs(FRAME_SLOTS) do if s == slot then return true end end
    return false
  end

  local sidesFake = { north = 2, south = 3, east = 4, west = 5, up = 0, down = 1 }
  local DOWN = sidesFake.down

  local component = {}
  component.isAvailable = function(name)
    return name == "robot" or name == "beekeeper" or name == "inventory_controller" or name == "computer"
  end

  local function wrapFacing(f) return ((f - 1) % 4) + 1 end

  -- select() is a raw component.robot method (inventory slot selection --
  -- no movement/animation involved). Movement itself
  -- (forward/turnLeft/turnRight/up/down) is NOT on the raw component at
  -- all -- confirmed on real hardware ("attempt to call a nil value
  -- (field 'turnRight')") -- it only exists on the high-level "robot"
  -- LIBRARY (require("robot")), so it's faked separately below and
  -- registered under package.loaded["robot"], not package.loaded["component"].
  component.robot = {
    select = function(slot) world.drone._selected = slot end,
    -- Splits `count` items off the currently selected slot into `toSlot`
    -- -- real robot.transferTo(slot, [count]), used by
    -- bee_keeper_manager.lua's ensureSingleItemSlot to peel exactly one
    -- drone off a stacked slot before swapDrone, instead of handing over
    -- the whole stack.
    transferTo = function(toSlot, count)
      local from = world.drone._selected
      local stack = world.drone.inventory[from]
      if not stack then return false end
      local size = stack.size or 1
      local moveCount = count or size
      if moveCount >= size then
        world.drone.inventory[toSlot] = stack
        world.drone.inventory[from] = nil
      else
        local newStack = {}
        for k, v in pairs(stack) do newStack[k] = v end
        newStack.size = moveCount
        stack.size = size - moveCount
        world.drone.inventory[toSlot] = newStack
      end
      return true
    end,
  }

  local robotLib = {
    -- Applies the step immediately (world.drone.x/z is the single source
    -- of truth the rest of this sim reads from), using the SAME facing
    -- convention bee_keeper_nav.lua tracks internally -- so its exact
    -- position tracking and this world's actual position never drift
    -- apart, and travel distance doesn't affect sim speed at all (pacing
    -- comes entirely from the Status.onChange hook instead).
    forward = function()
      if world.drone.facing == 1 then world.drone.z = world.drone.z + 1
      elseif world.drone.facing == 2 then world.drone.x = world.drone.x + 1
      elseif world.drone.facing == 3 then world.drone.z = world.drone.z - 1
      elseif world.drone.facing == 4 then world.drone.x = world.drone.x - 1 end
      return true
    end,
    turnRight = function()
      world.drone.facing = wrapFacing(world.drone.facing + 1)
      return true
    end,
    turnLeft = function()
      world.drone.facing = wrapFacing(world.drone.facing - 1)
      return true
    end,
    up = function() return true end,
    down = function() return true end,
    -- Own-inventory size, NOT inventory_controller.getInventorySize()
    -- (that one is for EXTERNAL inventories and requires a side --
    -- confirmed on real hardware; see bee_keeper_manager.lua's
    -- findHoneySlot/resolveWorkingSlots header notes).
    inventorySize = function() return world.cargoSize end,
  }

  component.inventory_controller = {
    -- EXTERNAL inventory size, side-relative -- always requires a side
    -- (own inventory size is robotLib.inventorySize() instead, see
    -- above). Trash is fixed at 1 slot, storage/apiary report their real
    -- configured/fixed sizes -- matches real hardware validating slot
    -- numbers against the actual target inventory (see M.harvestSite's
    -- header notes on the "invalid slot" crash this caught before).
    getInventorySize = function(side)
      if side ~= DOWN then return nil end
      if atTrash() then return 1 end
      if atStorage() then return world.storageSize end
      if apiaryAt(world.drone.x, world.drone.z) then return APIARY_SIZE end
      return nil
    end,
    getStackInInternalSlot = function(slot)
      if slot < 1 or slot > world.cargoSize then return nil end
      return world.drone.inventory[slot]
    end,
    getStackInSlot = function(side, slot)
      if side ~= DOWN then return nil end
      if atTrash() then return nil end -- auto-deleted, nothing to see from outside
      if atStorage() then
        if slot < 1 or slot > world.storageSize then return nil end
        return world.storage[slot]
      end
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a then return nil end
      if slot < 1 or slot > APIARY_SIZE then return nil end
      if slot == 1 then return a.princessRaw and toStack(a.princessRaw, "princess") or nil end
      if slot == 2 then return a.droneRaw and toStack(a.droneRaw, "drone") or nil end
      if isFrameSlot(slot) then return nil end -- frames, not modeled
      if a.products and a.products[slot] then return a.products[slot] end
      return nil
    end,
    -- Lands in the CURRENTLY SELECTED slot, same as dropIntoSlot below --
    -- not an auto-picked empty slot (matches real hardware; see
    -- bee_keeper_manager.lua's M.harvestSite header notes). Real
    -- stacking: merges into a matching, not-yet-full destination stack
    -- (capped at 64), creates a fresh one if empty, or fails outright if
    -- the destination holds something incompatible -- exactly like a
    -- real inventory slot, not a blind "+1".
    suckFromSlot = function(side, slot, count)
      if side ~= DOWN then return 0 end
      if atTrash() or atStorage() then return 0 end -- nothing to suck FROM there in this flow
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a or slot < 1 or slot > APIARY_SIZE or isFrameSlot(slot) then return 0 end
      if not a.products or not a.products[slot] then return 0 end

      local source = a.products[slot]
      local selected = world.drone._selected
      local moved = depositInto(world.drone.inventory, selected, source, count or 1)
      if moved > 0 then
        source.size = (source.size or 1) - moved
        if source.size <= 0 then a.products[slot] = nil end
      end
      return moved
    end,
    -- Deposits the ENTIRE currently selected stack -- storage/trash
    -- discards always move the whole stack at once (there's no reason to
    -- split a discard the way ensureSingleItemSlot splits an apiary
    -- LOAD). Trash auto-deletes on contact: the item just vanishes,
    -- nothing is ever retained or readable back out.
    dropIntoSlot = function(side, slot)
      if side ~= DOWN then return false end
      local selected = world.drone._selected
      local stack = world.drone.inventory[selected]
      if not stack then return false end

      if atTrash() then
        if slot ~= 1 then return false end
        world.drone.inventory[selected] = nil
        return true
      end

      if atStorage() then
        if slot < 1 or slot > world.storageSize then return false end
        local moved = depositInto(world.storage, slot, stack, stack.size or 1)
        if moved <= 0 then return false end
        stack.size = (stack.size or 1) - moved
        if stack.size <= 0 then world.drone.inventory[selected] = nil end
        return true
      end

      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a or slot < 1 or slot > APIARY_SIZE or isFrameSlot(slot) or slot == 1 or slot == 2 then
        return false -- princess/drone slots are only ever set via swapQueen/swapDrone, not a raw drop
      end
      a.products = a.products or {}
      local moved = depositInto(a.products, slot, stack, stack.size or 1)
      if moved <= 0 then return false end
      stack.size = (stack.size or 1) - moved
      if stack.size <= 0 then world.drone.inventory[selected] = nil end
      return true
    end,
  }

  component.beekeeper = {
    canWork = function(side)
      if side ~= DOWN then return false end
      local a = apiaryAt(world.drone.x, world.drone.z)
      return a ~= nil and a.droneRaw ~= nil and a.workTicks < a.workNeeded
    end,
    getBeeProgress = function(side)
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a then return 0 end
      -- Advance work by one tick each time progress is checked -- this is
      -- the "does it eventually finish" heartbeat.
      if a.droneRaw and a.workTicks < a.workNeeded then
        a.workTicks = a.workTicks + 1
        if a.workTicks >= a.workNeeded then
          -- One offspring: a fresh cross, plus a mutation roll if both
          -- parents match a recipe.
          local function makeOffspring()
            local child = crossRaw(world.traitList, a.princessRaw, a.droneRaw)
            for targetSpecies, recipes in pairs(world.mutationRecipes) do
              for _, recipe in ipairs(recipes) do
                local nameA = a.princessRaw.species.active.name
                local nameB = a.droneRaw.species.active.name
                local wantA, wantB = recipe.allele1.name, recipe.allele2.name
                local matches = (nameA == wantA and nameB == wantB) or (nameA == wantB and nameB == wantA)
                if matches and math.random(100) <= recipe.chance then
                  local sp = { name = targetSpecies, uid = "sim." .. targetSpecies:lower(), humidity = "Normal", temperature = "Normal" }
                  child.species = { active = sp, inactive = sp }
                end
              end
            end
            return child
          end

          -- The queen is CONSUMED (queen slot goes empty), and her
          -- replacement offspring princess lands in the product/output
          -- area alongside the drones and combs -- NOT back in the queen
          -- slot. Confirmed against real hardware via
          -- probeInventoryBelow(): a spent apiary's queen slot (1) comes
          -- back completely empty, with the replacement princess sitting
          -- among slots 3+ like any other harvestable product. Nothing
          -- re-seeds a new queen automatically -- that's
          -- bee_keeper_manager.lua's M.runQualitySite's job (see its
          -- findPrincessCandidate), which this sim needs to actually
          -- exercise the same as real hardware does.
          --
          -- The replacement princess and the drone offspring are
          -- INDEPENDENT draws from the same mating pair, and nothing gets
          -- to select the princess -- see bee_breeding_test.lua's header
          -- on that mechanic. All computed before princessRaw is cleared,
          -- so they all descend from the same parents.
          local newPrincess = makeOffspring()

          -- Output area is slots 6-12 (7 slots) -- 1-2 are princess/drone,
          -- 3-5 are frames. Tries to merge into an existing matching
          -- output stack first (real stacking, capped at 64), same as
          -- anything else in this sim -- two mating cycles producing the
          -- same drone genotype back-to-back should stack together, not
          -- spread across separate output slots one at a time.
          a.products = a.products or {}
          local function addProduct(newStack)
            for outSlot = FIRST_OUTPUT_SLOT, APIARY_SIZE do
              local existing = a.products[outSlot]
              if existing == nil then
                a.products[outSlot] = cloneStack(newStack, newStack.size or 1)
                return
              elseif depositInto(a.products, outSlot, newStack, newStack.size or 1) > 0 then
                return
              end
            end
            -- Every output slot full and none compatible -- real Forestry
            -- would just have nowhere to put it either; drop it silently
            -- rather than erroring, matching "the apiary is jammed" but
            -- for a demo/local run this only happens if you're not
            -- harvesting at all.
          end

          addProduct(toStack(newPrincess, "princess"))
          for _ = 1, 2 do
            addProduct(toStack(makeOffspring(), "drone"))
          end

          a.princessRaw = nil
          a.droneRaw = nil
        end
      end
      return (a.workTicks / a.workNeeded) * 100
    end,
    -- The princess/queen slot only ever accepts princess/queen items --
    -- per your spec, "princess and drone breeding take 2 and can only
    -- occupy their respective slots". Swapping in anything else (a
    -- drone, an empty selection) fails outright rather than silently
    -- accepting it, so a manager logic bug (picking the wrong slot)
    -- shows up as a failed swap instead of corrupting apiary state.
    swapQueen = function(side)
      if side ~= DOWN then return false end
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a then return false end
      local selected = world.drone._selected
      local newQueen = world.drone.inventory[selected]
      if newQueen and not isPrincessOrQueenStack(newQueen) then return false end
      local oldQueenRaw = a.princessRaw
      a.princessRaw = newQueen and newQueen.individual and rawFromIndividual(newQueen.individual, newQueen._uid) or nil
      world.drone.inventory[selected] = oldQueenRaw and toStack(oldQueenRaw, "princess") or nil
      a.workTicks = 0
      return true
    end,
    swapDrone = function(side)
      if side ~= DOWN then return false end
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a then return false end
      local selected = world.drone._selected
      local newDrone = world.drone.inventory[selected]
      if newDrone and not isDroneStack(newDrone) then return false end
      local oldDroneRaw = a.droneRaw
      a.droneRaw = newDrone and newDrone.individual and rawFromIndividual(newDrone.individual, newDrone._uid) or nil
      world.drone.inventory[selected] = oldDroneRaw and toStack(oldDroneRaw, "drone") or nil
      a.workTicks = 0
      return true
    end,
    analyze = function() return true end, -- everything in this sim is pre-analyzed
  }

  component.bee_housing = {
    getBeeParents = function(targetSpecies) return world.mutationRecipes[targetSpecies] or {} end,
  }

  -- Fake GPU: bee_keeper_ui.lua's M.draw talks to component.gpu directly
  -- (set/setForeground/fill), not term, since per-cell color needs
  -- absolute positioning. Reproduced here with real ANSI escapes (24-bit
  -- "true color", `\27[38;2;r;g;bm`) so the colored dashboard is actually
  -- visible in a local terminal too, not just in-game -- most modern
  -- terminals (Windows Terminal, PowerShell 7+) support this; older
  -- consoles without VT processing will just show plain text.
  --
  -- Frame size: if opts.uiWidth/uiHeight are BOTH given, that's an
  -- explicit request (e.g. a "WxH" CLI arg) and is honored as-is (see
  -- M.resolveTermSize) -- otherwise it's fit to the REAL terminal
  -- (best-effort), because the dashboard uses absolute cursor addressing
  -- and a fixed frame taller or WIDER than the window scrolls the top
  -- off: rows wider than the window wrap (doubling the effective
  -- height), and writing the bottom-right cell auto-advances and scrolls
  -- one line. Fixed by (a) fitting/sizing the frame correctly and (b)
  -- M.beginScreen disabling auto-wrap.
  local termW, termH = M.resolveTermSize(opts.uiWidth, opts.uiHeight)
  local fgColor = 0xFFFFFF
  component.gpu = {
    getResolution = function() return termW, termH end,
    setForeground = function(color) fgColor = color end,
    getForeground = function() return fgColor end,
    fill = function(x, y, w, h, char)
      -- M.draw only ever fills the whole screen with " " to clear it.
      io.write("\27[2J\27[H")
    end,
    set = function(x, y, text)
      local r = (fgColor >> 16) & 0xFF
      local g = (fgColor >> 8) & 0xFF
      local b = fgColor & 0xFF
      io.write(string.format("\27[%d;%dH\27[38;2;%d;%d;%dm%s\27[0m", y, x, r, g, b, text))
    end,
  }
  M.beginScreen()

  local computerFake = {
    energy = function() return world.drone.energy end,
    maxEnergy = function() return 1 end,
    beep = function() end, -- no audio locally; bee_keeper_setup's border-preview signal just no-ops
  }

  package.loaded["sides"] = sidesFake
  package.loaded["component"] = component
  package.loaded["computer"] = computerFake
  package.loaded["robot"] = robotLib

  -- os.sleep must exist (production code calls it), but does nothing real
  -- here -- pacing comes from the Status.onChange hook in
  -- bee_keeper_local_sim_run.lua, so a real sleep here would double it up.
  os.sleep = function() end

  M.world = world
  return world
end

return M
