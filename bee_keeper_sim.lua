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

-- Deterministic, ARBITRARY dominance rank for a species name (higher = more
-- dominant). Real per-species dominance isn't exposed by the OC API (the probe
-- showed no such method), and the robot's logic must be correct for ANY
-- dominance assignment -- so the sim just needs a stable pseudo-rank to
-- reproduce the real behavior "a hybrid expresses its DOMINANT species allele as
-- active" (see docs/gtnh_bee_genetics.md). That's what forces the genebank to
-- reason by GENOTYPE (active==inactive) rather than by the displayed species,
-- and is exactly the case that bit the old naive purification.
local function speciesDominanceRank(name)
  local h = 0
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 1000003 end
  return h
end
M.speciesDominanceRank = speciesDominanceRank

-- parentA/parentB: { [trait] = { active = rawValue, inactive = rawValue } }
-- Each offspring allele is one random pick from each parent. For the SPECIES
-- locus the expressed (active) allele is then the DOMINANT of the two (higher
-- rank); on a tie, or equal species, order is left as-is. Other traits keep the
-- simple active=parentA / inactive=parentB assignment (dominance there doesn't
-- affect the species-drift problem and would perturb the traitmax tests).
local function crossRaw(traitList, parentA, parentB)
  local child = {}
  for _, trait in ipairs(traitList) do
    local a = pickRawAllele(parentA[trait])
    local b = pickRawAllele(parentB[trait])
    if trait == "species" and a and b and a.name and b.name then
      if speciesDominanceRank(b.name) > speciesDominanceRank(a.name) then
        a, b = b, a
      end
    end
    child[trait] = { active = a, inactive = b }
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

-- Builds a raw genotype starting from makeStartingRaw's all-bad
-- baseline, but with good alleles swapped in for ONLY the traits in
-- goodTraitSet ({ trait = true, ... }) -- used for the "hard" seeding
-- scenario (see M.newWorld's opts.hard): good alleles are scattered
-- across SEVERAL different starting individuals instead of any one of
-- them already having everything, so reaching a fully purebred bee
-- genuinely requires combining different lineages via real breeding
-- over multiple generations, not just getting lucky with an
-- instant-good bee on cycle 1.
local function makePartialGoodRaw(traitList, speciesName, goodTraitSet)
  local g = makeStartingRaw(traitList, speciesName)
  for trait in pairs(goodTraitSet) do
    if g[trait] then
      local spec = Cfg.targets[trait]
      g[trait] = { active = (spec and spec.target) or 0, inactive = (spec and spec.target) or 0 }
    end
  end
  return g
end

-- Splits every quality trait (excludes "species") into 3 roughly-equal
-- groups -- shared by the traitmax and species "hard" seeding scenarios
-- in M.newWorld below.
local function qualityTraitGroups(traitList)
  local qualityTraits = {}
  for _, t in ipairs(traitList) do
    if t ~= "species" then table.insert(qualityTraits, t) end
  end
  local groups = { {}, {}, {} }
  for i, t in ipairs(qualityTraits) do
    table.insert(groups[((i - 1) % 3) + 1], t)
  end
  return groups
end

local function toSet(list)
  local set = {}
  for _, t in ipairs(list) do set[t] = true end
  return set
end

-- Converts a raw genotype (active/inactive per trait) into the
-- stack.individual shape bee_keeper_manager.lua's readIndividual expects.
-- Skips "_uid" -- toStack (below) caches a per-individual id directly on
-- the raw genotype table, which isn't a trait and doesn't have
-- .active/.inactive fields. isAnalyzed defaults to true (demo starting
-- stock is pre-identified) -- freshly bred offspring explicitly pass
-- false (see getBeeProgress's makeOffspring), matching real Forestry:
-- you have to identify a newly bred bee with honey before its traits
-- are known.
local function toIndividual(rawGenotype, isAnalyzed)
  local active, inactive = {}, {}
  for trait, alleles in pairs(rawGenotype) do
    if trait ~= "_uid" then
      active[trait] = alleles.active
      inactive[trait] = alleles.inactive
    end
  end
  return { active = active, inactive = inactive, isAnalyzed = isAnalyzed ~= false }
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
-- this sim unable to ever exercise that code path at all. isAnalyzed
-- (default true) only matters at CREATION time -- the resulting stack
-- is what actually gets stored (in cargo, or an apiary's products), and
-- read back as-is thereafter, so there's no need to cache analyzed
-- status on the raw genotype the way _uid is cached. The one place
-- toStack re-derives from persistent raw data on every read (an
-- apiary's princessRaw/droneRaw peek) only ever holds bees that were
-- ALREADY analyzed before being swapped in, so defaulting true there is
-- always correct.
local function toStack(rawGenotype, kind, isAnalyzed)
  if rawGenotype._uid == nil then rawGenotype._uid = nextUid() end
  local name = "forestry:bee"
  if kind == "princess" then name = "Forestry:beePrincessGE"
  elseif kind == "drone" then name = "Forestry:beeDroneGE" end
  return { name = name, size = 1, maxSize = 64, individual = toIndividual(rawGenotype, isAnalyzed), _uid = rawGenotype._uid }
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

-- Shallow-copies a flat { trait = rawValue, ... } table -- the allele
-- values themselves (numbers/strings/booleans/species tables) are never
-- mutated in place anywhere, only replaced wholesale, so one level of
-- copying is enough to make active/inactive independent between split
-- stacks.
local function shallowCopyTable(t)
  local copy = {}
  for k, v in pairs(t) do copy[k] = v end
  return copy
end

-- Copies a stack's fields into a brand-new table -- used whenever a NEW
-- stack needs to exist independently of its source (so mutating the
-- copy's .size later doesn't also change the original). .individual gets
-- a DEEP copy (not just the outer stack table) -- this is what happens
-- whenever a stacked quantity gets split (e.g. depositInto pulling 1 of
-- 2 identical drones into cargo): without deep-copying, both halves
-- shared the exact same .individual table, so analyzing the CARGO half
-- (setting .isAnalyzed = true) silently marked the OTHER, still-in-the-
-- apiary half as analyzed too, even though it was never actually
-- identified with honey.
local function cloneStack(stack, size)
  local copy = {}
  for k, v in pairs(stack) do copy[k] = v end
  if stack.individual then
    local ind = stack.individual
    copy.individual = {
      isAnalyzed = ind.isAnalyzed,
      active = ind.active and shallowCopyTable(ind.active) or nil,
      inactive = ind.inactive and shallowCopyTable(ind.inactive) or nil,
    }
  end
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

-- opts.hard: scatters good alleles across SEVERAL different starting
-- individuals (see makePartialGoodRaw) instead of handing over an
-- instant-good bee -- see the seeding block below for exactly how the
-- traits get split up.
function M.newWorld(config, sites, opts)
  opts = opts or {}
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
    -- uid + stepCounter snapshot of the bee (princess OR drone) most
    -- recently moved (loaded into an apiary or discarded), so the
    -- verbose dump can flash its WHOLE row cyan for the ENTIRE task/step
    -- it becomes visible in (not just a single redraw) -- see
    -- M.tickStep/flashRow below. stepCounter increments once per
    -- Status.onChange (one whole task), driven from outside by
    -- M.tickStep -- NOT per Nav.onStep block-move, so a multi-block walk
    -- redraws with the flash held steady the whole time instead of it
    -- vanishing after the first block.
    recentlyMovedBeeUid = nil,
    recentlyMovedBeeStep = nil,
    stepCounter = 0,
    mutationRecipes = {
      -- Demo fallback used ONLY when no real graph is supplied
      -- (opts.mutationGraph) -- a generous chance so a quick local demo
      -- shows a mutation succeed within a few cycles. Directional:
      -- allele1 = princess, allele2 = drone.
      ["NewBee"] = {
        { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 50 },
      },
    },
    -- Set of special-condition strings the "user" has satisfied (foundation
    -- block placed, in the right dimension, etc.). nil = permissive: every
    -- condition is treated as met (the default for a headless demo, where
    -- we assume the setup is in place). A test can set this to an explicit
    -- set to model gating -- makeOffspring only fires a conditioned
    -- mutation once all its conditions are members.
    satisfiedConditions = nil,
  }

  -- Directional pair index for mutation rolls: "<princessSpecies>|<droneSpecies>"
  -- -> { { result, chance, conditions }, ... }. Built from the REAL GTNH
  -- graph (opts.mutationGraph, a bee_mutation_graph.build result) when
  -- given, else from the demo table above. allele1/princess is the first
  -- key component, allele2/drone the second -- matching is NOT symmetric.
  world.mutationPairIndex = {}
  local function addPair(p, d, result, chance, conditions)
    local key = p .. "|" .. d
    world.mutationPairIndex[key] = world.mutationPairIndex[key] or {}
    table.insert(world.mutationPairIndex[key], { result = result, chance = chance or 0, conditions = conditions or {} })
  end
  if opts.mutationGraph then
    for result, recipes in pairs(opts.mutationGraph.byResult) do
      for _, r in ipairs(recipes) do addPair(r.princess, r.drone, result, r.chance, r.conditions) end
    end
  else
    for result, recipes in pairs(world.mutationRecipes) do
      for _, r in ipairs(recipes) do addPair(r.allele1.name, r.allele2.name, result, r.chance, {}) end
    end
  end

  -- Whether every one of a recipe's special conditions is currently
  -- satisfied (see world.satisfiedConditions). Permissive by default.
  function world.conditionsMet(conditions)
    if not conditions or #conditions == 0 then return true end
    if not world.satisfiedConditions then return true end
    for _, c in ipairs(conditions) do
      if not world.satisfiedConditions[c] then return false end
    end
    return true
  end

  -- Sites start with EMPTY apiaries, regardless of mode -- a real apiary
  -- might have leftover state from previous Minecraft play the sim has
  -- no way to know about, so the safe, consistent assumption is "nothing
  -- there yet". This exercises bee_keeper_manager.lua's OWN
  -- princess-seeding (findPrincessCandidate) and drone-loading logic
  -- from a cold start, same as a freshly placed apiary would need.
  for _, s in ipairs(sites) do
    world.apiaries[s.x .. ":" .. s.z] = { princessRaw = nil, droneRaw = nil, workTicks = 0, workNeeded = 2 }
  end

  -- Seed a real starting population, split across cargo AND storage --
  -- since apiaries start empty (above), bee_keeper_manager.lua needs
  -- something to actually bootstrap from: a princess-type item for every
  -- species a site needs, plus a handful of drones to choose among.
  -- put() seeds cargo (config.workingSlots, skipping honeySlot, so
  -- seeding can't silently clobber the honey slot or land outside the
  -- pool bee_keeper_manager.lua actually looks at); putStorage() seeds
  -- storage directly, so M.restockFromStorage's fallback path is
  -- exercised from cycle 1, not only after the first discard.
  local nextWorkingSlotIndex = 1
  local function put(rawGenotype, kind, size)
    while config.workingSlots[nextWorkingSlotIndex] == config.honeySlot do
      nextWorkingSlotIndex = nextWorkingSlotIndex + 1
    end
    local slot = config.workingSlots[nextWorkingSlotIndex]
    nextWorkingSlotIndex = nextWorkingSlotIndex + 1
    local stack = toStack(rawGenotype, kind or "drone")
    if size then stack.size = size end
    world.drone.inventory[slot] = stack
  end

  local nextStorageSlot = 1
  local function putStorage(rawGenotype, kind, size)
    local stack = toStack(rawGenotype, kind or "drone")
    if size then stack.size = size end
    world.storage[nextStorageSlot] = stack
    nextStorageSlot = nextStorageSlot + 1
  end

  if opts.hard then
    -- HARD scenario: no single starting bee already has every trait
    -- fixed. Every quality trait's good allele DOES exist somewhere in
    -- the starting population (otherwise purebred would be literally
    -- unreachable -- Mendelian inheritance can't invent an allele from
    -- nothing), split across three DIFFERENT drone lineages, each
    -- covering only a third of the traits -- reaching a fully purebred
    -- bee now genuinely requires combining those lineages together via
    -- several real generations of breeding, not getting lucky with an
    -- instant-good bee on cycle 1. FOUR copies of each lineage are
    -- seeded, not one -- each trait still segregates independently
    -- every generation (real Mendelian risk, same as bee_breeding_test.
    -- lua's own tracked "permanent allele loss" metric -- a real
    -- possibility there too, just rare), so a single copy risked losing
    -- an entire group forever to one unlucky non-inheritance roll
    -- (confirmed empirically: never reached purebred in 500 cycles),
    -- and even two copies still lost a trait outright in a sampled run.
    -- Four copies is extra insurance beyond bee_breeding.lua's normal
    -- minCopies=2, specifically because THIS scenario starts with zero
    -- redundancy anywhere else in the population (every OTHER trait
    -- already has a "safe" GG source from the other lineages) -- it
    -- makes loss rare without making it impossible, so "hard" stays a
    -- genuine (if unlikely) risk, not a guarantee -- and even without
    -- any loss at all, actually recombining all 9 traits into ONE
    -- princess simultaneously (via a single blind random succession
    -- each generation, not a deliberate pick -- see bee_breeding_test.
    -- lua's header notes) is itself a slow, genuinely hard process, not
    -- guaranteed to finish within any particular number of cycles --
    -- that's the whole point of "hard" mode, not a bug to fix.
    local groups = qualityTraitGroups(traitList)

    -- 4 copies of each lineage -- 2 in cargo, 2 in storage -- reduces
    -- (does not eliminate) the chance of a trait vanishing outright
    -- before it ever gets combined with the other lineages.
    put(makeStartingRaw(traitList, "Forest"), "princess")
    for _, group in ipairs(groups) do
      put(makePartialGoodRaw(traitList, "Forest", toSet(group)))
    end
    putStorage(makeStartingRaw(traitList, "Forest"), "princess")
    for _, group in ipairs(groups) do
      put(makePartialGoodRaw(traitList, "Forest", toSet(group)))
    end
    for _, group in ipairs(groups) do
      putStorage(makePartialGoodRaw(traitList, "Forest", toSet(group)))
    end
  else
    -- General-purpose population for traitmax sites (species-agnostic)
    -- -- 2 princesses + 2 drones in cargo, 1 more of each in storage,
    -- enough to bootstrap a handful of traitmax apiaries within the
    -- first couple of cycles without waiting on organic growth.
    put(makeStartingRaw(traitList, "Forest"), "princess")
    put(makeGoodRaw(traitList, "Forest"))
    put(makeStartingRaw(traitList, "Forest"))
    put(makeGoodRaw(traitList, "Forest"), "princess")
    putStorage(makeStartingRaw(traitList, "Forest"), "princess")
    putStorage(makeGoodRaw(traitList, "Forest"))
  end

  -- Seeded once per DISTINCT targetSpecies, not once per site -- sites
  -- sharing the same target (the normal case: both CLI runners assign
  -- ONE mode/targetSpecies to every site in a run) would otherwise each
  -- demand their own full set of cargo slots, easily overflowing
  -- workingSlots' fixed size (confirmed: 3 same-target species sites in
  -- "hard" mode tried to claim 21 slots on top of the general
  -- population's own 7, well past the usual 15 available).
  local seededSpecies = {}
  for _, s in ipairs(sites) do
    if s.mode == "mutation" and not seededSpecies["mut:" .. tostring(s.targetSpecies)] then
      seededSpecies["mut:" .. tostring(s.targetSpecies)] = true
      -- Seed the BASE LEAF bees the target's breeding tree actually needs
      -- (opts.mutationLeaves, computed by the caller from the real graph),
      -- one princess AND one drone of each -- so the sim can execute the
      -- WHOLE multi-step tree autonomously (each intermediate gets bred
      -- from these, then combined further), and the manager's planner
      -- deterministically prefers the path through these owned leaves.
      -- Extra copies in storage give the run something to restock from as
      -- the seed pairs get consumed. With no graph/leaves supplied, fall
      -- back to the classic Forest(princess) x Meadows(drone) demo pair.
      local leaves = opts.mutationLeaves
      if leaves and #leaves > 0 then
        -- A princess plus an AMPLE stack of drones per leaf: a mutation is
        -- probabilistic per mating (~8-15%) and a princess-x-drone cross of
        -- two homozygous leaves yields offspring that all take the
        -- princess's active species, so the leaf DRONE species never
        -- regenerates -- without a real stock the run would exhaust its few
        -- drones before the mutation ever rolls. A 32-deep stack (each
        -- mating peels one off) gives plenty of attempts, plus a storage
        -- backup to restock from.
        local LEAF_DRONE_STACK = 32
        -- Princesses are the sustainable resource but they DO get consumed
        -- each mating, and when a mutation fires on the princess draw the
        -- replacement takes the mutated species instead of the leaf's -- so
        -- a leaf princess line can dwindle under several contending apiaries.
        -- Stock a reserve in storage (restockFromStorage pulls them back)
        -- so a multi-step demo doesn't stall waiting on a base princess.
        local LEAF_PRINCESS_RESERVE = 6
        for _, leaf in ipairs(leaves) do
          put(makeStartingRaw(traitList, leaf), "princess")
          put(makeStartingRaw(traitList, leaf), "drone", LEAF_DRONE_STACK)
          for _ = 1, LEAF_PRINCESS_RESERVE do
            putStorage(makeStartingRaw(traitList, leaf), "princess")
          end
          putStorage(makeStartingRaw(traitList, leaf), "drone", LEAF_DRONE_STACK)
        end
      else
        put(makeStartingRaw(traitList, "Forest"), "princess")
        put(makeStartingRaw(traitList, "Meadows"), "drone")
      end
    elseif s.mode == "species" and s.targetSpecies and not seededSpecies[s.targetSpecies] then
      seededSpecies[s.targetSpecies] = true
      if opts.hard then
        -- Same "hard" treatment as the general traitmax population above
        -- (see its header notes for the full reasoning): the princess
        -- and every drone are already the correct targetSpecies -- an
        -- always-true state for species mode, matched by real Forestry
        -- (species purity, once achieved, doesn't randomly regress the
        -- way a quality trait can) -- but the QUALITY traits are
        -- scattered across separate lineages instead of any one of them
        -- already being fully purebred. Reaching a genuinely perfect
        -- purebred-species bee now takes real generations of combining
        -- them, not an instant win on cycle 1.
        local groups = qualityTraitGroups(traitList)
        put(makeStartingRaw(traitList, s.targetSpecies), "princess")
        for _, group in ipairs(groups) do
          put(makePartialGoodRaw(traitList, s.targetSpecies, toSet(group)))
        end
        putStorage(makeStartingRaw(traitList, s.targetSpecies), "princess")
        for _, group in ipairs(groups) do
          put(makePartialGoodRaw(traitList, s.targetSpecies, toSet(group)))
        end
        for _, group in ipairs(groups) do
          putStorage(makePartialGoodRaw(traitList, s.targetSpecies, toSet(group)))
        end
      else
        put(makeGoodRaw(traitList, s.targetSpecies), "princess")
        put(makeGoodRaw(traitList, s.targetSpecies), "drone")
      end
    end
  end

  world.drone.inventory[config.honeySlot] = { name = "forestry:honey_drop", size = 64, maxSize = 64 }
  -- Backup honey in storage too -- analyze() now actually consumes it
  -- (see component.beekeeper.analyze below), so cargo's stock is finite
  -- and will genuinely run dry over a long run. Without a backup
  -- somewhere else, M.restockHoney's fallback path would have nothing to
  -- find and analysis would just permanently stop working. Several full
  -- stacks (not just one) -- a single 64-stack restock trip empties the
  -- ENTIRE backup in one go (suckFromSlot pulls a whole matching stack,
  -- capped at MAX_STACK=64 per slot), leaving nothing for any FUTURE
  -- restock once that single stack was ever tapped. A long run (or
  -- "hard" mode's many extra generations, each producing more
  -- unanalyzed offspring) burns through honey much faster than a quick
  -- demo does -- confirmed empirically: a single backup stack (64) ran
  -- completely dry by cycle ~30 of a "hard" species run, and even 6
  -- backup stacks (384) only lasted to cycle 126. 12 stacks (768, plus
  -- cargo's own 64 = 832 total) lasts roughly 250 cycles in that same
  -- worst-case scenario -- comfortably past any normal test/demo run,
  -- while still leaving real headroom in storage's 27-slot default
  -- (hard mode's own scattered lineages already use up to 8 slots
  -- there).
  local HONEY_BACKUP_STACKS = 12
  for _ = 1, HONEY_BACKUP_STACKS do
    world.storage[nextStorageSlot] = { name = "forestry:honey_drop", size = 64, maxSize = 64 }
    nextStorageSlot = nextStorageSlot + 1
  end

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
  local world = M.newWorld(config, sites, opts)
  world.cargoSize = opts.cargoSize or 16
  world.storageSize = opts.storageSize or 27

  local function apiaryAt(x, z) return world.apiaries[x .. ":" .. z] end
  local function atPos(px, pz) return px ~= nil and world.drone.x == px and world.drone.z == pz end
  local function atStorage() return config.storagePos and atPos(config.storagePos.x, config.storagePos.z) end
  local function atTrash() return config.trashPos and atPos(config.trashPos.x, config.trashPos.z) end
  local function atCharger() return config.chargerPos and atPos(config.chargerPos.x, config.chargerPos.z) end

  -- Real hardware genuinely drains energy per block moved -- world.drone.
  -- energy was previously set once at world creation and never touched
  -- again anywhere, so Nav.needCharge could never trigger and the drone
  -- would never even attempt to visit the charger. ENERGY_PER_BLOCK is a
  -- fraction of a full charge (not absolute EU, matching how this sim's
  -- energy is read elsewhere as a 0..1 fraction) -- picked so a full
  -- charge lasts roughly 200 blocks of travel, occasionally showing
  -- charging behavior without draining every few steps.
  local ENERGY_PER_BLOCK = 0.005
  -- Passive recharge while standing at the charger -- ticks up on every
  -- energy() poll, mirroring real hardware where the charger increases
  -- energy in the background and Nav.chargeAtHome just polls it in a
  -- loop. Chunky enough that the poll loop (see computerFake.energy
  -- below) finishes in a bounded, small number of iterations instead of
  -- spinning forever -- os.sleep is a no-op in this sim, so nothing else
  -- would ever advance real time between polls.
  local ENERGY_CHARGE_PER_POLL = 0.05

  -- Stamps world.recentlyMovedBeeUid/Step together (always as a pair --
  -- see M.tickStep/flashRow for how the step snapshot decides how long
  -- the cyan flash stays visible). Applies to EITHER role -- a princess
  -- being seeded into an apiary is just as much "a bee that just moved"
  -- as a drone being loaded or discarded.
  local function markBeeMoved(stack)
    if not stack or not stack._uid then return end
    if not (isPrincessOrQueenStack(stack) or isDroneStack(stack)) then return end
    world.recentlyMovedBeeUid = stack._uid
    world.recentlyMovedBeeStep = world.stepCounter
  end

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
    -- Merges into whatever's ALREADY in toSlot if it matches (real
    -- robot.transferTo behaves like any other inventory slot move --
    -- it merges into a compatible existing stack, same as
    -- suckFromSlot/dropIntoSlot elsewhere in this file). Previously
    -- this just overwrote toSlot outright, silently discarding
    -- whatever was already there -- harmless for ensureSingleItemSlot's
    -- use (always targets a slot it already confirmed is empty), but
    -- broke M.analyzeWorkingSlots' post-analysis re-consolidation
    -- (moving a freshly-analyzed bee into an existing matching analyzed
    -- stack) by destroying the destination stack instead of growing it.
    transferTo = function(toSlot, count)
      local from = world.drone._selected
      local stack = world.drone.inventory[from]
      if not stack then return false end
      local size = stack.size or 1
      local moveCount = count or size
      local moved = depositInto(world.drone.inventory, toSlot, stack, moveCount)
      if moved <= 0 then return false end
      stack.size = size - moved
      if stack.size <= 0 then world.drone.inventory[from] = nil end
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
      world.drone.energy = math.max(0, (world.drone.energy or 0) - ENERGY_PER_BLOCK)
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
    -- Works against EITHER storage (M.restockFromStorage pulls bees back
    -- out of it) or an apiary's output slots (M.harvestSite) -- same
    -- branching as getStackInSlot/dropIntoSlot below. Trash never has
    -- anything to suck FROM (it auto-deletes on contact).
    suckFromSlot = function(side, slot, count)
      if side ~= DOWN then return 0 end
      if atTrash() then return 0 end

      local sourceContainer, sourceSlot
      if atStorage() then
        if slot < 1 or slot > world.storageSize then return 0 end
        sourceContainer, sourceSlot = world.storage, slot
      else
        local a = apiaryAt(world.drone.x, world.drone.z)
        if not a or slot < 1 or slot > APIARY_SIZE or isFrameSlot(slot) or slot == 1 or slot == 2 then
          return 0 -- princess/drone slots only ever move via swapQueen/swapDrone
        end
        a.products = a.products or {}
        sourceContainer, sourceSlot = a.products, slot
      end

      local source = sourceContainer[sourceSlot]
      if not source then return 0 end

      local selected = world.drone._selected
      local moved = depositInto(world.drone.inventory, selected, source, count or 1)
      if moved > 0 then
        source.size = (source.size or 1) - moved
        if source.size <= 0 then sourceContainer[sourceSlot] = nil end
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
        markBeeMoved(stack)
        return true
      end

      if atStorage() then
        if slot < 1 or slot > world.storageSize then return false end
        local moved = depositInto(world.storage, slot, stack, stack.size or 1)
        if moved <= 0 then return false end
        stack.size = (stack.size or 1) - moved
        if stack.size <= 0 then world.drone.inventory[selected] = nil end
        markBeeMoved(stack)
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
            -- DIRECTIONAL mutation roll: the princess-slot species is
            -- allele1, the drone-slot species is allele2 -- look up that
            -- exact ordered pair (not the reverse). A conditioned recipe
            -- only fires if its special conditions are currently met (see
            -- world.conditionsMet). First matching successful roll wins.
            local P = a.princessRaw.species.active.name
            local D = a.droneRaw.species.active.name
            local recipes = world.mutationPairIndex[P .. "|" .. D]
            if recipes then
              for _, recipe in ipairs(recipes) do
                if world.conditionsMet(recipe.conditions) and math.random(100) <= recipe.chance then
                  local sp = { name = recipe.result, uid = "sim." .. recipe.result:lower(), humidity = "Normal", temperature = "Normal" }
                  child.species = { active = sp, inactive = sp }
                  break
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

          -- Freshly bred bees start UNANALYZED -- real Forestry doesn't
          -- reveal a newly bred individual's traits until you identify
          -- it with honey (see the analyze() implementation below).
          addProduct(toStack(newPrincess, "princess", false))
          for _ = 1, 2 do
            addProduct(toStack(makeOffspring(), "drone", false))
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
      if newQueen then markBeeMoved(newQueen) end
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
      if newDrone then markBeeMoved(newDrone) end
      return true
    end,
    -- Consumes 1 honey/honeydew from honeySlot (real Forestry: analyzing
    -- identifies a bee by consuming a unit of honey) and marks the
    -- CURRENTLY SELECTED cargo slot's bee as analyzed. Fails if honeySlot
    -- is empty or isn't actually honey -- matches real hardware, and is
    -- what makes M.analyzeWorkingSlots/M.restockHoney's fallback path
    -- worth exercising at all instead of honey being a no-op fiction.
    analyze = function(honeySlot)
      local honey = world.drone.inventory[honeySlot]
      if not honey or not honey.name or not honey.name:lower():find("honey") then
        return false
      end
      honey.size = (honey.size or 1) - 1
      if honey.size <= 0 then world.drone.inventory[honeySlot] = nil end

      local selected = world.drone._selected
      local stack = world.drone.inventory[selected]
      if stack and stack.individual then stack.individual.isAnalyzed = true end
      return true
    end,
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
    -- Passive recharge while standing at the charger, ticking up on
    -- every poll -- see ENERGY_CHARGE_PER_POLL's header notes. Real
    -- hardware's charger increases energy in the background
    -- independently of anything the manager code does; Nav.chargeAtHome
    -- just polls computer.energy() in a loop, so ticking it up HERE (the
    -- only thing actually being polled) is what makes that loop actually
    -- terminate in this sim, instead of energy sitting frozen forever.
    energy = function()
      if atCharger() then
        world.drone.energy = math.min(1, (world.drone.energy or 0) + ENERGY_CHARGE_PER_POLL)
      end
      return world.drone.energy
    end,
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

-- ============================================================
-- Verbose debugging dump
-- ============================================================

-- Explicit abbreviations -- trait:sub(1,4) collides ("flowering" and
-- "flowerProvider" would both truncate to "flow").
local TRAIT_ABBR = {
  fertility = "fert",
  lifespan = "life",
  flowering = "flwg",
  flowerProvider = "flpr",
  temperatureTolerance = "temp",
  humidityTolerance = "humid",
  nocturnal = "noct",
  tolerantFlyer = "tfly",
  caveDwelling = "cave",
}

local COLOR_DEFAULT = 0xE0E0E0
local COLOR_PRINCESS = 0xFF69B4 -- pink
local COLOR_DRONE = 0xFFA030 -- orange
-- Cyan whole-row flash for a bee that just moved (see world.recentlyMovedBeeUid
-- and flashRow below). Only ever applied to segments that are still
-- COLOR_DEFAULT at that point -- princess pink, drone orange, and the
-- allele green/red already painted by traitSegments all stay layered on
-- top, untouched.
local COLOR_MOVED = 0x00E0E0 -- cyan, momentary
local COLOR_GOOD = 0x00E000 -- green, matches the "good" allele
local COLOR_BAD = 0xE00000 -- red, matches the "bad" allele

-- A line is an ARRAY of { text=, color= } segments, not a plain string --
-- lets each allele letter (see traitSegments below) and the
-- princess/drone item name get its own color instead of one flat color
-- per line. line(...) takes any number of (text, color) pairs and
-- assembles them into one such line for readability at each call site.
local function line(...)
  local args = { ... }
  local segments = {}
  for i = 1, #args, 2 do
    table.insert(segments, { text = args[i], color = args[i + 1] or COLOR_DEFAULT })
  end
  return segments
end

-- Appends every segment of `more` onto `segments` in place.
local function append(segments, more)
  for _, seg in ipairs(more) do table.insert(segments, seg) end
  return segments
end

-- Whether `stack` is the bee world.recentlyMovedBeeUid/Step is currently
-- flashing for -- true for exactly the step it was moved becoming
-- visible in (stepCounter advanced by 1 since the move), per M.tickStep.
local function wasRecentlyMoved(stack)
  local world = M.world
  if not (world and stack and stack._uid) then return false end
  return stack._uid == world.recentlyMovedBeeUid
    and world.recentlyMovedBeeStep ~= nil
    and (world.stepCounter - world.recentlyMovedBeeStep) <= 1
end

-- Flashes an ENTIRE row (e.g. a prefix like "  slot 2 (drone): " appended
-- with formatStackSegments' own output) cyan when `shouldFlash` is true
-- -- but only for segments still at COLOR_DEFAULT. Princess pink, drone
-- orange, and allele green/red are each a deliberate, "outside of normal
-- white" color already, so they stay layered on top untouched instead of
-- being overridden. Returns a NEW array -- never mutates `segments`, so
-- the same formatStackSegments call stays reusable elsewhere unflashed.
local function flashRow(segments, shouldFlash)
  if not shouldFlash then return segments end
  local flashed = {}
  for _, seg in ipairs(segments) do
    local color = (seg.color == COLOR_DEFAULT) and COLOR_MOVED or seg.color
    table.insert(flashed, { text = seg.text, color = color })
  end
  return flashed
end

-- GG/Gb/bG/bb per active/meaningful trait (excludes "any"-kind traits
-- like effect/territory/speed, which don't have a meaningful good/bad
-- state to show), each allele letter individually colored green (good)
-- or red (bad). Returns a single segment saying "unidentified" for an
-- unanalyzed bee -- matches real Forestry: you can't see a bee's traits
-- until you identify it with honey.
--
-- targetSpecies: species is genetically just another chromosome (see
-- bee_trait_config.lua's header notes) and bee_keeper_manager.lua
-- tracks it as an active trait exactly like any other whenever a site
-- has a real target (species/mutation modes -- see M.traitListFor).
-- Shown here the SAME way: GG/Gb/bb, green/red per allele, whenever a
-- targetSpecies is known. Without one (traitmax mode, or a cargo/
-- storage bee not tied to any one site's target), there's no "good"
-- species to score against -- scoring it "bad" by default would be
-- actively misleading (implying every species is wrong when none is
-- targeted), so the raw species name is shown instead, unscored.
local function traitSegments(individual, targetSpecies)
  if not individual.isAnalyzed then
    return { { text = "unidentified", color = COLOR_DEFAULT } }
  end
  local traits = Cfg.activeTraits()
  local genotype = Cfg.normalizeGenotype(traits, individual.active, individual.inactive, nil)
  local segments = {}
  for i, trait in ipairs(traits) do
    if i > 1 then table.insert(segments, { text = ",", color = COLOR_DEFAULT }) end
    table.insert(segments, { text = (TRAIT_ABBR[trait] or trait) .. "=", color = COLOR_DEFAULT })
    local state = BB.traitState(genotype, trait) -- e.g. "GG", "Gb", "bG", "bb"
    for allele in state:gmatch(".") do
      table.insert(segments, { text = allele, color = (allele == "G") and COLOR_GOOD or COLOR_BAD })
    end
  end

  table.insert(segments, { text = ",", color = COLOR_DEFAULT })
  table.insert(segments, { text = "species=", color = COLOR_DEFAULT })
  if targetSpecies then
    local speciesGenotype = Cfg.normalizeGenotype({ "species" }, individual.active, individual.inactive, targetSpecies)
    local state = BB.traitState(speciesGenotype, "species")
    for allele in state:gmatch(".") do
      table.insert(segments, { text = allele, color = (allele == "G") and COLOR_GOOD or COLOR_BAD })
    end
  else
    local species = individual.active and individual.active.species
    table.insert(segments, { text = species and Cfg.speciesKey(species) or "?", color = COLOR_DEFAULT })
  end

  return segments
end

-- showTraits: pass true to append the trait-state summary (see
-- traitSegments) -- per your call, shown for cargo/storage always, and
-- for an apiary's princess/drone specifically, but NOT its output slots.
-- The item name itself is colored pink for a princess/queen, orange for
-- a drone -- these (and the allele green/red from traitSegments) are the
-- row's own "real" colors; the moved-bee cyan flash is layered on top of
-- everything ELSE afterward, by flashRow, not decided here.
local function formatStackSegments(stack, showTraits, targetSpecies)
  if not stack then return { { text = "empty", color = COLOR_DEFAULT } } end

  local nameColor = COLOR_DEFAULT
  if isPrincessOrQueenStack(stack) then
    nameColor = COLOR_PRINCESS
  elseif isDroneStack(stack) then
    nameColor = COLOR_DRONE
  end

  local segments = { { text = stack.name, color = nameColor } }

  if stack.individual then
    local species = stack.individual.active and stack.individual.active.species
    local speciesName = species and Cfg.speciesKey(species) or "?"
    local uidStr = stack._uid and (" [uid=" .. stack._uid .. "]") or ""
    table.insert(segments, {
      text = string.format(" x%s (%s)%s", tostring(stack.size or 1), speciesName, uidStr),
      color = COLOR_DEFAULT,
    })
    if showTraits then
      table.insert(segments, { text = " {", color = COLOR_DEFAULT })
      append(segments, traitSegments(stack.individual, targetSpecies))
      table.insert(segments, { text = "}", color = COLOR_DEFAULT })
    end
  else
    table.insert(segments, { text = string.format(" x%s", tostring(stack.size or 1)), color = COLOR_DEFAULT })
  end

  return segments
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

-- Renders one line's segments as 24-bit ANSI true color -- the default
-- sink (console/log use). bee_keeper_local_sim_run.lua's "ui" mode
-- passes a different sink that paints each segment at an absolute gpu
-- position instead.
local function ansiPrintSink(segments)
  local parts = {}
  for _, seg in ipairs(segments) do
    local r = (seg.color >> 16) & 0xFF
    local g = (seg.color >> 8) & 0xFF
    local b = seg.color & 0xFF
    table.insert(parts, string.format("\27[38;2;%d;%d;%dm%s", r, g, b, seg.text))
  end
  print(table.concat(parts) .. "\27[0m")
end

-- Dumps EVERYTHING in the simulated world -- the agent's own
-- status (position/facing/energy/selected slot), cargo, storage, and
-- every apiary's queen/drone/output slots -- read directly off world
-- state, not through the side-relative production API (this is a
-- debugging tool with full internal access, unlike
-- bee_keeper_manager.lua, which can only ever see whatever's directly
-- below it). Meant to be called from bee_keeper_local_sim_run.lua's
-- "verbose" flag.
--
-- sink defaults to ansiPrintSink (console/log use), but accepts any
-- function(segments) -- segments is an array of { text=, color= }, not a
-- plain string, so callers can paint each piece (allele letters,
-- princess/drone names) in its own color. bee_keeper_local_sim_run.lua's
-- "ui" mode passes one that writes each segment to an absolute gpu
-- position instead, so verbose output can be part of the live
-- dashboard, not separate scrolling text that would corrupt its
-- fixed-position redraws.
--
-- sites (optional) is config.sites -- used to label each apiary with its
-- real site name (e.g. "apiary1"), the SAME name Status.setStep uses in
-- the top step message. Without it, apiaries fall back to being labeled
-- by their "x:z" key, sorted alphabetically -- which does NOT match site
-- order/naming and was the source of a real mismatch bug.
function M.dumpWorld(sink, sites)
  sink = sink or ansiPrintSink
  local world = M.world
  if not world then return end

  -- Species is genetically just another chromosome, tracked as an
  -- active trait exactly like any other whenever a site actually has a
  -- target (species/mutation modes -- see M.traitListFor). posToSite
  -- lets each apiary's princess/drone be scored against ITS OWN site's
  -- target; globalTargetSpecies is the fallback for cargo/storage bees,
  -- which aren't tied to any one site -- the first tracked target found
  -- across all sites (this local sim always runs every site under the
  -- same mode/targetSpecies anyway, so "first found" covers the normal
  -- case).
  local posToName = {}
  local posToSite = {}
  local globalTargetSpecies = nil
  if sites then
    for _, s in ipairs(sites) do
      posToName[s.x .. ":" .. s.z] = s.name
      posToSite[s.x .. ":" .. s.z] = s
      if not globalTargetSpecies and (s.mode == "species" or s.mode == "mutation") and s.targetSpecies then
        globalTargetSpecies = s.targetSpecies
      end
    end
  end

  sink(line(string.format("--- drone/agent --- pos=(%d,%d) facing=%d energy=%.0f%% selected slot=%s",
    world.drone.x, world.drone.z, world.drone.facing, (world.drone.energy or 0) * 100,
    tostring(world.drone._selected))))
  sink(line(""))

  sink(line("--- cargo ---"))
  local cargoSlots = sortedKeys(world.drone.inventory)
  if #cargoSlots == 0 then sink(line("  (empty)")) end
  for _, slot in ipairs(cargoSlots) do
    local stack = world.drone.inventory[slot]
    local row = append(line(string.format("  slot %d: ", slot)), formatStackSegments(stack, true, globalTargetSpecies))
    sink(flashRow(row, wasRecentlyMoved(stack)))
  end
  sink(line(""))
  sink(line(""))

  sink(line("--- storage ---"))
  local storageSlots = sortedKeys(world.storage)
  if #storageSlots == 0 then sink(line("  (empty)")) end
  for _, slot in ipairs(storageSlots) do
    local stack = world.storage[slot]
    local row = append(line(string.format("  slot %d: ", slot)), formatStackSegments(stack, true, globalTargetSpecies))
    sink(flashRow(row, wasRecentlyMoved(stack)))
  end
  sink(line(""))
  sink(line(""))

  sink(line("--- apiaries ---"))
  for _, key in ipairs(sortedKeys(world.apiaries)) do
    local a = world.apiaries[key]
    local label = posToName[key] or key
    sink(line(string.format("  %s @ (%s) -- work %d/%d:", label, key, a.workTicks, a.workNeeded)))

    -- This apiary's OWN site target, not the global fallback -- a
    -- traitmax site has no meaningful species target even if some OTHER
    -- site in the same run does.
    local site = posToSite[key]
    local siteTargetSpecies = site and (site.mode == "species" or site.mode == "mutation")
      and site.targetSpecies or nil

    local princessStack = a.princessRaw and toStack(a.princessRaw, "princess") or nil
    local princessRow = append(line("    slot 1 (princess): "),
      princessStack and formatStackSegments(princessStack, true, siteTargetSpecies) or line("empty"))
    sink(flashRow(princessRow, wasRecentlyMoved(princessStack)))

    local droneStack = a.droneRaw and toStack(a.droneRaw, "drone") or nil
    local droneRow = append(line("    slot 2 (drone): "),
      droneStack and formatStackSegments(droneStack, true, siteTargetSpecies) or line("empty"))
    sink(flashRow(droneRow, wasRecentlyMoved(droneStack)))

    local productSlots = sortedKeys(a.products or {})
    if #productSlots == 0 then
      sink(line("    outputs (6-12): (empty)"))
    else
      for _, slot in ipairs(productSlots) do
        local stack = a.products[slot]
        local row = append(line(string.format("    slot %d (output): ", slot)), formatStackSegments(stack))
        sink(flashRow(row, wasRecentlyMoved(stack)))
      end
    end
    sink(line(""))
  end
end

-- Advances the step counter the cyan "bee just moved" row flash is timed
-- against (see world.recentlyMovedBeeStep/wasRecentlyMoved). Call this
-- exactly once per NEW task/step (i.e. from Status.onChange), NOT per
-- Nav.onStep block-move -- so a multi-block walk redraws with the flash
-- held steady for its entire duration instead of it decaying after the
-- first block.
function M.tickStep()
  if M.world then M.world.stepCounter = M.world.stepCounter + 1 end
end

return M
