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
local function toIndividual(rawGenotype)
  local active, inactive = {}, {}
  for trait, alleles in pairs(rawGenotype) do
    active[trait] = alleles.active
    inactive[trait] = alleles.inactive
  end
  return { active = active, inactive = inactive, isAnalyzed = true }
end
-- kind ("princess"/"drone"/nil) picks a real Forestry-style item name --
-- bee_keeper_manager.lua's findPrincessCandidate matches on item name
-- (case-insensitive "princess"/"queen"), so a generic name would make
-- this sim unable to ever exercise that code path at all.
local function toStack(rawGenotype, kind)
  local name = "forestry:bee"
  if kind == "princess" then name = "Forestry:beePrincessGE"
  elseif kind == "drone" then name = "Forestry:beeDroneGE" end
  return { name = name, individual = toIndividual(rawGenotype) }
end

-- Inverse of toIndividual -- extracts a raw genotype (active/inactive per
-- trait) back out of an individual table. Used when the production code
-- swaps a stack from cargo into an apiary slot.
local function rawFromIndividual(individual)
  local g = {}
  for trait, activeValue in pairs(individual.active) do
    g[trait] = { active = activeValue, inactive = individual.inactive[trait] }
  end
  return g
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
  local function put(rawGenotype)
    while config.workingSlots[nextWorkingSlotIndex] == config.honeySlot do
      nextWorkingSlotIndex = nextWorkingSlotIndex + 1
    end
    local slot = config.workingSlots[nextWorkingSlotIndex]
    nextWorkingSlotIndex = nextWorkingSlotIndex + 1
    world.drone.inventory[slot] = toStack(rawGenotype, "drone")
  end

  put(makeGoodRaw(traitList, "Forest"))
  put(makeStartingRaw(traitList, "Forest"))
  put(makeGoodRaw(traitList, "Forest"))

  for _, s in ipairs(sites) do
    if s.mode == "mutation" then
      put(makeStartingRaw(traitList, "Forest"))
      put(makeStartingRaw(traitList, "Meadows"))
    elseif s.mode == "species" and s.targetSpecies then
      put(makeGoodRaw(traitList, s.targetSpecies))
    end
  end

  world.drone.inventory[config.honeySlot] = { name = "forestry:honey_drop", size = 64 }

  return world
end

-- ============================================================
-- Fake hardware, backed by the world above
-- ============================================================

function M.install(config, sites, opts)
  opts = opts or {}
  local world = M.newWorld(config, sites)

  local function apiaryAt(x, z) return world.apiaries[x .. ":" .. z] end
  local function atStorage()
    return config.storagePos and world.drone.x == config.storagePos.x and world.drone.z == config.storagePos.z
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
  }

  component.inventory_controller = {
    -- 15 covers the widest range this sim's apiaries/storage ever use
    -- (config.productSlots, config.storageSlotCount) -- real hardware
    -- reports its own real size per-inventory; this just needs to be
    -- "big enough" so M.harvestSite's size-guard never filters out a
    -- product slot the sim actually populates.
    getInventorySize = function(side) return side == DOWN and 15 or nil end,
    getStackInInternalSlot = function(slot) return world.drone.inventory[slot] end,
    getStackInSlot = function(side, slot)
      if side ~= DOWN then return nil end
      if atStorage() then return world.storage[slot] end
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a then return nil end
      if slot == 1 then return a.princessRaw and toStack(a.princessRaw, "princess") or nil end
      if slot == 2 then return a.droneRaw and toStack(a.droneRaw, "drone") or nil end
      if a.products and a.products[slot] then return a.products[slot] end
      return nil
    end,
    -- Lands in the CURRENTLY SELECTED slot, same as dropIntoSlot above --
    -- not an auto-picked empty slot (matches real hardware; see
    -- bee_keeper_manager.lua's M.harvestSite header notes). If the
    -- destination is already occupied, this models a real inventory's
    -- merge (increments size) rather than refusing -- production code
    -- only ever selects an occupied slot via findStackingSlot, which
    -- already verified it's a genuine match.
    suckFromSlot = function(side, slot)
      if side ~= DOWN then return 0 end
      local a = apiaryAt(world.drone.x, world.drone.z)
      local selected = world.drone._selected
      if a and a.products and a.products[slot] then
        local existing = world.drone.inventory[selected]
        if existing then
          existing.size = (existing.size or 1) + 1
        else
          world.drone.inventory[selected] = a.products[slot]
        end
        a.products[slot] = nil
        return 1
      end
      return 0
    end,
    dropIntoSlot = function(side, slot)
      if side ~= DOWN or not atStorage() then return false end
      local selected = world.drone._selected
      local stack = world.drone.inventory[selected]
      if not stack then return false end
      local existing = world.storage[slot]
      if existing then
        existing.size = (existing.size or 1) + 1
      else
        world.storage[slot] = stack
      end
      world.drone.inventory[selected] = nil
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

          a.products = a.products or {}
          local nextProductSlot = 3
          local function addProduct(stack)
            while a.products[nextProductSlot] do nextProductSlot = nextProductSlot + 1 end
            a.products[nextProductSlot] = stack
            nextProductSlot = nextProductSlot + 1
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
    swapQueen = function(side)
      if side ~= DOWN then return false end
      local a = apiaryAt(world.drone.x, world.drone.z)
      if not a then return false end
      local selected = world.drone._selected
      local newQueen = world.drone.inventory[selected]
      local oldQueenRaw = a.princessRaw
      a.princessRaw = newQueen and newQueen.individual and rawFromIndividual(newQueen.individual) or nil
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
      local oldDroneRaw = a.droneRaw
      a.droneRaw = newDrone and newDrone.individual and rawFromIndividual(newDrone.individual) or nil
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
