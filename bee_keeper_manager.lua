--[[
  Bee Keeper Manager
  -------------------
  Orchestrates Forestry bee breeding via OpenComputers' UpgradeBeekeeper
  (component "beekeeper") instead of a fixed Transposer network. An Agent
  (Robot or Drone) carrying this upgrade interacts with whichever apiary is
  directly next to it, side-relative -- no wiring, no transposers.

  Everything below was confirmed by reading the actual mod source
  (li.cil.oc.integration.forestry.*), not guessed:

    - swapQueen(side)/swapDrone(side): swap whatever's in your CURRENTLY
      SELECTED inventory slot with the apiary's queen/drone slot. This is
      how you both load a fresh pair AND harvest a spent queen -- whatever
      was sitting there comes back into your selected slot.
    - getBeeProgress(side)/canWork(side): apiary status, side-relative.
    - analyze(honeySlot): analyzes the bee in your selected slot, consuming
      1 honey/honeydew from the given slot.
    - None of these require the apiary to be a registered OC component --
      UpgradeBeekeeperUtil queries the world position at `side` directly.
    - inventory_controller's slot-peek/suck/drop methods (getStackInSlot,
      getStackInInternalSlot, suckFromSlot) are IDENTICAL between the Robot
      and Drone variants (confirmed in UpgradeInventoryController.scala) --
      this manager doesn't care which host it's running on for those.
    - A bee's genome, read via inventory_controller (getStackInSlot /
      getStackInInternalSlot), comes back as stack.individual.{active,
      inactive,isAnalyzed,...} (matching beeManager.lua's established
      convention). bee_housing.getQueen()/getDrone() return the individual
      itself, UNWRAPPED (no .individual nesting) -- see readIndividual()
      below, which handles both shapes.
    - The mutation graph (bee_housing / tile_for_apiculture getBeeBreedingData)
      is NOT reachable from a moving robot -- only a stationary OC Adapter
      next to an apiary exposes it (confirmed). So it's dumped ONCE from
      such a setup, shipped as bee_mutations.dat, and loaded at startup
      into config.mutationGraph (see M.loadMutationGraph). The mutation
      mode's tree planning lives in the pure bee_mutation_graph module.

  ASSUMED HARDWARE (flag if wrong, easy to adjust):
    - Agent (Robot or Drone) with "beekeeper" AND "inventory_controller"
      upgrades installed.
    - Honey/honeydew stock sitting in a known slot (config.honeySlot).
    - A handful of "working slots" in the agent's own inventory used as the
      live candidate-bee pool (config.workingSlots) -- this replaces
      beeManager.lua's big storage-chest catalog; there's no room for that
      here, so the pool is just whatever fits in cargo at once.

  MOVEMENT: sites are (x,z) positions at one fixed Y level (see
  bee_keeper_nav.lua) -- the drone flies DIRECTLY above each apiary and
  always interacts via sides.down, never side-relative horizontal offsets.
  Site positions come from bee_keeper_setup.lua's area scan, persisted to
  disk; see M.loadSites for how those get merged with the mode/
  targetSpecies assignments you configure by hand.

  THREE MODES (per site, set via config.siteOverrides[name].mode, default
  "traitmax" for anything not overridden):
    "traitmax" -- no species target. Get as close to a max-trait bee as
                  possible from whatever's on hand; species is untracked.
                  This is the fallback/default: even if parents have no
                  good alleles at all, it always makes the locally best
                  available choice each cycle (bee_breeding.lua never
                  requires reaching the target to make progress).
    "species"  -- you already hold at least one specimen (any quality) of
                  targetSpecies. Purify toward pure-species + max traits
                  simultaneously by tracking species as just one more
                  trait (bee_trait_config.lua/bee_breeding.lua's
                  species-as-a-trait support).
    "mutation" -- you do NOT yet hold targetSpecies. Look up its mutation
                  recipe (candidate parent-species pairs + base chance),
                  match against species you actually hold, load the best
                  satisfiable pair, and keep re-attempting (mutation is
                  probabilistic per successful mating in Forestry). Once
                  any specimen of targetSpecies shows up in the harvest,
                  the site's mode is expected to be switched to "species"
                  (see M.checkMutationSuccess) so it takes over from there.
--]]

local BB = require("bee_breeding")
local Cfg = require("bee_trait_config")
local Nav = require("bee_keeper_nav")
local Status = require("bee_keeper_status")
local MG = require("bee_mutation_graph")
local GB = require("bee_genebank")
local Sched = require("bee_genebank_scheduler")
local Rainbow = require("bee_rainbow")
local Traitmax = require("bee_traitmax")
local Templates = require("bee_templates")
local Program = require("bee_program")
local Combine = require("bee_combine")
local Pool = require("bee_pool")

local M = {}
M.Nav = Nav

-- ============================================================
-- Hardware access (lazy -- resolved on first use, not at require time, so
-- this module can be `require`d for testing outside Minecraft with a
-- mocked "component"/"sides" pair of modules pre-seeded into
-- package.loaded).
-- ============================================================

local function component() return require("component") end
local function sides() return require("sides") end

local function beekeeper() return component().beekeeper end
local function invCtrl() return component().inventory_controller end
local function agent()
  local c = component()
  if c.isAvailable("robot") then return c.robot end
  return c.drone
end

-- The "robot" LIBRARY (require("robot")), not component.robot -- needed
-- for inventorySize(), which reports the agent's OWN total slot count.
-- inventory_controller.getInventorySize(side) is for EXTERNAL
-- inventories and REQUIRES a side argument -- confirmed on real hardware
-- ("bad arguments #1 (integer expected, got no value)") when called with
-- none, which is what querying "my own size" would need. Same
-- library-vs-component split bee_keeper_nav.lua already established for
-- movement.
local function robotLib() return require("robot") end

-- ============================================================
-- Genome reading
-- ============================================================

-- A bee's genome comes back two different shapes depending on API used:
--   - inventory_controller stack descriptions nest it under .individual
--   - bee_housing.getQueen()/getDrone() return the individual UNWRAPPED
-- This normalizes both into the individual table itself, or nil if the
-- given value isn't an analyzed bee.
local function readIndividual(raw)
  if not raw then return nil end
  local individual = raw.individual or raw
  if not individual.isAnalyzed then return nil end
  if not individual.active or not individual.inactive then return nil end
  return individual
end
M.readIndividual = readIndividual

-- Peek at a slot in the agent's own inventory (does NOT consume/move
-- anything). Returns the individual table, or nil if empty/not a bee/not
-- analyzed.
function M.readOwnSlot(slot)
  local stack = invCtrl().getStackInInternalSlot(slot)
  return readIndividual(stack)
end

-- Peek at a slot of the inventory on the given side (e.g. an apiary's
-- queen slot = 1, drone slot = 2). Does NOT consume/move anything.
function M.readSideSlot(side, slot)
  local stack = invCtrl().getStackInSlot(side, slot)
  return readIndividual(stack)
end

-- Lists the agent's own occupied cargo slots as { {slot=N, stack=rawStack}, ... }
-- -- for bee_keeper_ui.lua's cargo panel. Unlike readOwnSlot, returns the
-- RAW stack (not just .individual), since the UI wants to show non-bee
-- items (honey) too, not just analyzed bees. Always safe to call: reading
-- your own inventory has no position constraint, unlike an external one
-- (see M.listStorage in bee_keeper_local_sim_run.lua's real-hardware note).
function M.listCargo(config)
  local list = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack then table.insert(list, { slot = slot, stack = stack }) end
  end
  return list
end

-- Fraction (0..1) of tracked loci already fixed to GG (homozygous good) --
-- i.e. how close this bee is to fully purebred-perfect. 1.0 means every
-- tracked trait is locked in and BB.isPurebred would return true.
function M.purityOf(traitList, genotype)
  if #traitList == 0 then return 0 end
  local fixed = 0
  for _, trait in ipairs(traitList) do
    if BB.traitState(genotype, trait) == "GG" then fixed = fixed + 1 end
  end
  return fixed / #traitList
end

-- Build a bee_breeding.lua-compatible {id, genotype} from something an
-- inventory read/peek returned, or nil if it's not a usable analyzed bee.
local function toBreedingBee(id, individual, traitList, targetSpecies)
  if not individual then return nil end
  local genotype = Cfg.normalizeGenotype(traitList, individual.active, individual.inactive, targetSpecies)
  return { id = id, genotype = genotype, _individual = individual }
end
M.toBreedingBee = toBreedingBee

-- ============================================================
-- Trait list per mode
-- ============================================================

-- traitmax: quality traits only, species untracked/ignored entirely.
-- species: quality traits + species (targetSpecies decides "good" there).
function M.traitListFor(mode)
  local traits = Cfg.activeTraits()
  if mode == "species" or mode == "mutation" then
    table.insert(traits, "species")
  end
  return traits
end

-- ============================================================
-- Movement: sites are (x,z) at the fixed flight altitude; always
-- interact via sides.down once positioned directly above.
-- ============================================================

local function gotoSite(site)
  return Nav.gotoXZ(site.x, site.z)
end
M.gotoSite = gotoSite

-- ============================================================
-- Core per-site cycle: traitmax / species modes
-- (identical machinery -- they differ only in traitListFor's output and
-- whether targetSpecies is set)
-- ============================================================

-- Matched by item name, case-insensitively, since Forestry's own
-- princess/queen items both qualify (a queen is just a mated princess).
local function isPrincessOrQueenStack(stack)
  if not stack or not stack.name then return false end
  local lower = stack.name:lower()
  return lower:find("princess") ~= nil or lower:find("queen") ~= nil
end

local function isDroneStack(stack)
  if not stack or not stack.name then return false end
  return stack.name:lower():find("drone") ~= nil
end

-- Split isPrincessOrQueenStack's two cases apart. In Forestry an UNMATED
-- princess is a "Princess" item; the moment she mates she becomes a distinct
-- "Queen" item that then breeds and is consumed. The loaders need to tell
-- these apart: a princess in slot 1 still WANTS a drone; a queen there is
-- already breeding and must be left completely alone.
local function isQueenStack(stack)
  if not stack or not stack.name then return false end
  return stack.name:lower():find("queen") ~= nil
end
local function isPrincessStack(stack)
  if not stack or not stack.name then return false end
  local l = stack.name:lower()
  return l:find("princess") ~= nil and not l:find("queen")
end

-- Classify what's sitting in an apiary's queen(1)/drone(2) slots so the
-- per-site loaders never drop a fresh drone (or clobber a queen) next to a
-- bee that's already set up. PURE (takes the two raw stacks straight from
-- getStackInSlot) so it's unit-testable off-hardware, and it reads the raw
-- item NAME -- not the analyzed genome -- because a freshly mated queen is
-- often still unanalyzed yet must still be recognized and protected.
--   "empty"    slot 1 empty            -> free to seed a princess
--   "unpaired" princess, drone slot empty -> the ONE state where we load a drone
--   "paired"   princess + a drone already present -> cross is committed; do NOT
--              re-pick a drone (that repeated re-swapping is the "random"
--              re-breeding the user is seeing)
--   "queen"    a MATED queen (or any unexpected slot-1 occupant) -> she is
--              breeding regardless of what canWork() momentarily reports
--              (output full, wrong climate/time can all read false); loading a
--              drone here can't fertilize her, it only strands a drone in slot 2
function M.classifyApiaryLoad(slot1, slot2)
  if not slot1 then return "empty" end
  if isQueenStack(slot1) then return "queen" end
  -- Anything that reads as a princess -- by item name, OR simply by being an
  -- analyzed bee that ISN'T a queen (slot 1 only ever holds a princess or a
  -- queen) -- still needs (or already has) a drone.
  if isPrincessStack(slot1) or (slot1.individual and slot1.individual.isAnalyzed) then
    return isDroneStack(slot2) and "paired" or "unpaired"
  end
  -- A non-bee / unrecognized occupant: leave it be rather than clobber it.
  return "queen"
end

-- Thin hardware wrapper: read the real apiary slots and classify them.
function M.apiaryLoadState(down)
  local ic = invCtrl()
  return M.classifyApiaryLoad(ic.getStackInSlot(down, 1), ic.getStackInSlot(down, 2))
end

-- Shared guard for every site runner: once past the canWork()/harvest block,
-- refuse to touch an apiary that already holds a breeding queen or a
-- fully-loaded princess+drone pair. Returns a status string to bail with, or
-- nil to proceed with seeding/loading. Placed AFTER reclaimLoneDrone so a
-- genuinely lone drone (slot 1 empty) has already been pulled back first.
function M.apiaryLoadGuard(down, site)
  local state = M.apiaryLoadState(down)
  if state == "queen" then
    return "queen breeding at " .. (site.name or "?") .. " -- left untouched"
  elseif state == "paired" then
    return "pair already loaded at " .. (site.name or "?") .. " -- waiting to start"
  end
  return nil
end

-- Gathers usable candidate DRONES from the working slots (analyzed bees
-- only -- unanalyzed ones are queued for analysis instead, see
-- M.analyzeWorkingSlots). Explicitly excludes princess/queen items --
-- without this, a harvested princess sitting in cargo (e.g. waiting to be
-- re-seeded via M.runQualitySite's findPrincessCandidate below) gets
-- scored and treated as an ordinary breeding drone by
-- bee_breeding.planGeneration, and if she isn't picked as the "best
-- drone" this cycle, ends up in plan.toDiscard and gets flown to
-- storage/trash right along with actually-unwanted drones. This is
-- exactly what real hardware hit: a princess got stored instead of
-- staying available to re-seed her own apiary.
local function gatherCandidateDrones(config, traitList, targetSpecies)
  local pool = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local individual = readIndividual(stack)
    if individual and not isPrincessOrQueenStack(stack) then
      local bee = toBreedingBee("slot" .. slot, individual, traitList, targetSpecies)
      bee._slot = slot
      table.insert(pool, bee)
    end
  end
  return pool
end

-- Finds the HIGHEST-QUALITY analyzed princess/queen sitting in the
-- agent's own cargo, for seeding an apiary whose queen slot has gone
-- empty (see the no-princess branch in M.runQualitySite below for why
-- this is needed at all). Scored the same way as the mutation flow's
-- bestOfSpecies -- picking merely the FIRST candidate found (old
-- behavior) meant whichever princess happened to sit in the lowest-
-- numbered cargo slot got stuck in whichever apiary was visited first
-- (nearest-neighbor travel order), regardless of quality -- a genuinely
-- better princess could just as easily end up seeded at a LATER site
-- purely by luck of scan order, leaving a good drone (matched against
-- her via BB.planGeneration below) paired with a weak princess at the
-- site visited first, while a stronger princess sat unseeded in cargo.
-- Scoring here means the best available princess is always seeded
-- first, and with multiple apiaries needing seeding in the same cycle,
-- each one (visited in travel order) gets the best REMAINING princess
-- -- good pairs with good by construction, not accident.
-- Returns the working slot number, or nil if cargo has no usable
-- princess/queen at all.
local function findPrincessCandidate(config, traitList, targetSpecies)
  local bestSlot, bestScore = nil, -1
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if isPrincessOrQueenStack(stack) then
      local individual = readIndividual(stack)
      if individual then
        local genotype = Cfg.normalizeGenotype(traitList, individual.active, individual.inactive, targetSpecies)
        local score = M.purityOf(traitList, genotype)
        if score > bestScore then
          bestScore = score
          bestSlot = slot
        end
      end
    end
  end
  return bestSlot
end

-- swapDrone/swapQueen hand over the ENTIRE stack sitting in the currently
-- selected slot, not one item -- fine for a princess/queen (Forestry
-- never stacks those), but a drone slot can now legitimately hold
-- several genetically identical drones at once since harvestSite/
-- findStackingSlot started merging matches together. Splitting the
-- stack was the missing step: without this, loading "one drone" into an
-- apiary actually handed over the whole stack, wasting every extra
-- drone in it (the apiary only ever consumes one per mating). Returns
-- the slot now holding exactly ONE item (either the original slot
-- unchanged, or a freshly split-off single-item slot), or nil if the
-- stack needs splitting but no empty working slot is free to split into.
local function ensureSingleItemSlot(config, slot)
  local stack = invCtrl().getStackInInternalSlot(slot)
  if not stack or (stack.size or 1) <= 1 then return slot end

  for _, candidate in ipairs(config.workingSlots) do
    if candidate ~= slot and invCtrl().getStackInInternalSlot(candidate) == nil then
      agent().select(slot)
      if agent().transferTo(candidate, 1) then
        return candidate
      end
      return nil
    end
  end
  return nil
end

-- ============================================================
-- Perfect phase (bee_combine): serial trait imprinting
-- ============================================================
--
-- Breeds a species-X-pure bee that ALSO carries the maxed allele set, using the
-- traitmax MAX bee (a foreign species, all good) as the good-allele donor. Naive
-- species mode plateaus (species purity vs trait-fixing tension); bee_combine's
-- serial imprinting + partial-credit allele scoring converges (see
-- docs/perfect_combine_design.md). This handler is the hardware wiring of that
-- pure planner: pick the best PRINCESS and best DRONE by the current working-stage
-- fitness (role-aware, since a mating needs one of each), breed them, and let the
-- offspring accumulate the fixed loci over visits.

-- Adapter: a manager individual (active[locus]/inactive[locus]) -> the bee_combine
-- genome shape (g.species.{active,inactive}, g[trait].{active,inactive}).
local function toCombineGenome(ind, traitOrder)
  local g = { species = { active = ind.active.species, inactive = ind.inactive.species } }
  for _, t in ipairs(traitOrder) do
    g[t] = { active = ind.active[t], inactive = ind.inactive[t] }
  end
  return g
end

-- Combine pool from cargo: every analyzed bee as a bee_combine genome tagged with
-- its cargo slot and role.
local function gatherCombinePool(config, traitOrder)
  local pool = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local ind = readIndividual(stack)
    if ind then
      local g = toCombineGenome(ind, traitOrder)
      g._slot = slot
      g._princess = isPrincessOrQueenStack(stack)
      pool[#pool + 1] = g
    end
  end
  return pool
end

local function combineOpts(site)
  return {
    target = site.targetSpecies,
    traitOrder = site.perfectTraits or {},
    isGood = Cfg.isGoodValue,
    speciesKey = Cfg.speciesKey,
  }
end

-- Keep the CARGO breeding pool bounded and role-balanced (bee_pool). Each mating
-- yields 1 princess but 2 drones, so an unmanaged cargo floods with drones: once
-- full, offspring princesses can't land, the princess pool drains to zero, and
-- the loop freezes (the 8/9 convergence tail -- see docs/perfect_combine_design.md).
-- Before harvesting fresh offspring we hold cargo at top-K princesses + top-K
-- drones by combine fitness, flying the excess to OVERFLOW storage (genes kept,
-- not voided) so there's always room for the next generation. Gated on cargo
-- pressure so we don't make a needless storage trip every cycle.
--
-- protect: never discard (and don't let it consume a role cap) any bee that is
-- homozygous-good on ALL coverable traits -- that's the renewable good-allele
-- donor (our only allele source) and any already-perfect bee (finished progress).
-- Only the FEW highest-fitness working-trait carriers survive the cap; naive
-- "keep every carrier" over-protects when the donor has spread a trait widely
-- (nothing gets discarded, cargo stays full).
local function pruneCombinePool(config, opts)
  local free = 0
  for _, slot in ipairs(config.workingSlots) do
    if invCtrl().getStackInInternalSlot(slot) == nil then free = free + 1 end
  end
  if free >= (config.perfectMinFreeCargo or 6) then return 0 end

  -- Gather the ANALYZED pool (genes visible) plus the slots holding UNANALYZED
  -- drones. Analysis needs honey; when honey lags, offspring pile up unanalyzed
  -- and INVISIBLE to a genome-based prune, silently re-flooding cargo. So we also
  -- shed excess unanalyzed drones as a safety valve (below) -- the loop degrades
  -- gracefully instead of hard-freezing when analysis throughput can't keep up.
  local pool, unanalyzedDrones = {}, {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local ind = readIndividual(stack)
    if ind then
      pool[#pool + 1] = {
        _slot = slot,
        _princess = isPrincessOrQueenStack(stack),
        _g = toCombineGenome(ind, opts.traitOrder),
      }
    elseif stack and stack.individual and isDroneStack(stack) then
      unanalyzedDrones[#unanalyzedDrones + 1] = slot
    end
  end

  local nTraits = #opts.traitOrder
  -- protect ONLY a truly-finished perfect bee (species-pure target AND every
  -- coverable trait homozygous-good). It must NOT protect all-good SPECIES-HYBRIDS:
  -- once the donor's alleles spread, most of the pool becomes all-good-but-hybrid,
  -- and protecting all of them re-creates the very over-protection freeze this
  -- module exists to prevent (nothing left discardable -> cargo stays full).
  -- Hybrids and donors instead compete on the role caps by fitness; the renewable
  -- donor bank (traitmax max bee) keeps the good-allele source stocked.
  local function isPerfect(g)
    if opts.speciesKey(g.species.active) ~= opts.target or opts.speciesKey(g.species.inactive) ~= opts.target then
      return false
    end
    for _, t in ipairs(opts.traitOrder) do
      if not (opts.isGood(t, g[t].active) and opts.isGood(t, g[t].inactive)) then return false end
    end
    return true
  end
  local _, discard = Pool.balance(pool, {
    isPrincess = function(i) return i._princess end,
    fitness = function(i) return Combine.correctAlleles(i._g, nTraits, opts) end,
    maxPrincess = config.perfectMaxPrincess or 6,
    maxDrone = config.perfectMaxDrone or 8,
    protect = function(i) return isPerfect(i._g) end,
  })

  -- Shape discards for dumpEntriesAt ({ drone = { id, _slot } }); slot doubles as
  -- id (keepId nil -> nothing withheld).
  local entries = {}
  for _, i in ipairs(discard) do entries[#entries + 1] = { drone = { id = i._slot, _slot = i._slot } } end

  -- Safety valve: if the analyzed prune didn't free enough (cargo is choked with
  -- as-yet-unanalyzed offspring drones the genome prune can't see), shed the
  -- surplus unanalyzed drones too, keeping a small buffer. They go to overflow
  -- storage like everything else, so they can be pulled back and analyzed once
  -- there's room -- no genes voided.
  local target = config.perfectMinFreeCargo or 6
  local projectedFree = free + #entries
  local keepUnanalyzed = config.perfectMaxUnanalyzed or 4
  local i = keepUnanalyzed + 1
  while projectedFree < target and i <= #unanalyzedDrones do
    entries[#entries + 1] = { drone = { id = unanalyzedDrones[i], _slot = unanalyzedDrones[i] } }
    projectedFree = projectedFree + 1
    i = i + 1
  end

  if #entries == 0 then return 0 end
  -- Overflow storage preferred (genes kept); fall back to trash only if no
  -- storage is configured.
  if config.storagePos then
    M.dumpToStorage(config, entries, nil)
  elseif config.trashPos then
    M.dumpToTrash(config, entries, nil)
  end
  return #entries
end

function M.runPerfectSite(config, site)
  local opts = combineOpts(site)
  if not site.targetSpecies or #opts.traitOrder == 0 then
    return "perfect_no_target_or_traits"
  end
  -- Keep the cargo breeding pool bounded FIRST, every visit -- BEFORE anything
  -- else and independent of apiary state. This must not be gated behind a mating
  -- completing: a full cargo blocks seeding new matings, so nothing completes, so
  -- a completion-gated prune would never run again -- a deadlock that froze the
  -- pool at 8/9 (drones flood cargo, offspring princesses can't land). Pruning up
  -- front guarantees free slots for this visit's harvest and the next generation.
  -- (May fly to overflow storage; the gotoSite below returns us to the apiary.)
  pruneCombinePool(config, opts)

  Status.setStep("Heading to " .. (site.name or "?") .. " (perfect " .. site.targetSpecies .. ")")
  if not gotoSite(site) then return "nav_failed_to_apiary" end
  local down = sides().down

  -- Finish/collect any in-progress mating first (same pattern as runQualitySite):
  -- getBeeProgress completes the attempt on its final tick; if the queen is gone,
  -- harvest+analyze the offspring so they join the pool for this same decision.
  if beekeeper().canWork(down) then
    local progress = beekeeper().getBeeProgress(down)
    if M.readSideSlot(down, 1) ~= nil then
      return string.format("perfecting %s (%.0f%%)", site.targetSpecies, progress)
    end
    M.harvestSite(config, site)
    M.analyzeWorkingSlots(config)
  end

  -- Don't clobber a breeding queen or an already-loaded pair (see
  -- M.apiaryLoadGuard). runPerfectSite otherwise swapQueens a fresh princess
  -- in unconditionally, which on a canWork()==false read would replace a
  -- mid-cycle queen or re-pick the drone next to a committed cross.
  M.reclaimLoneDrone(config, site)
  local guarded = M.apiaryLoadGuard(down, site)
  if guarded then return guarded end

  local pool = gatherCombinePool(config, opts.traitOrder)
  if Combine.isDone(pool, opts) then
    -- A perfect bee is in cargo -- deposit to storage so the program's completion
    -- scan sees this species as perfected and rotates to the next.
    M.syncBanksToStorage(config)
    return "perfected:" .. site.targetSpecies
  end

  -- SPECIES-AWARE pair selection (serial imprint on real hardware, one pair at a
  -- time). A naive best-by-fitness pick erodes species purity -- it breeds the
  -- foreign donor into the princess line and never recovers X. Instead:
  --   * If NO X-carrier yet has the working trait's good allele -> INTRODUCE it:
  --     an X-carrier princess x the donor drone (offspring: X-hybrid carrying it,
  --     already-fixed traits preserved since the donor is good on them too).
  --   * Once X-carriers carry it -> HOMOZYGIZE within species X: breed the two
  --     best X-carriers so offspring recover X-pure AND fix the trait.
  -- xAlleles*BIG keeps species purity dominant over trait fitness in the pick.
  local order, tgt = opts.traitOrder, opts.target
  local stage = Combine.stage(pool, opts)
  local working = math.min(stage + 1, #order)
  local wt = order[working]
  local BIG = 100
  local function xAlleles(g)
    local n = 0
    if Cfg.speciesKey(g.species.active) == tgt then n = n + 1 end
    if Cfg.speciesKey(g.species.inactive) == tgt then n = n + 1 end
    return n
  end
  local function goodW(g) return opts.isGood(wt, g[wt].active) or opts.isGood(wt, g[wt].inactive) end
  local function fit(g) return Combine.correctAlleles(g, working, opts) end
  -- FITNESS-dominant with species as a tiebreak: a hybrid CARRYING the working
  -- trait's good allele must outrank an X-pure bee LACKING it, or the allele can
  -- never enter the X-pure line (species weight must not dominate fitness). x is
  -- only a tiebreak between equally-fit bees (prefer the purer one).
  local function xFit(g) return fit(g) * BIG + xAlleles(g) end
  local function pickBest(princess, filter, scoreFn)
    local best, bs
    for _, g in ipairs(pool) do
      if g._princess == princess and filter(g) then
        local s = scoreFn(g)
        if not best or s > bs then best, bs = g, s end
      end
    end
    return best
  end
  -- Princess protects the species line (prefer X-carriers, then fitness). Drone
  -- ALWAYS carries the working trait's good allele (goodW dominates), preferring
  -- an X-carrier that has it once one exists (so offspring can be X-pure + fixed),
  -- else the foreign donor (to keep introducing it). goodW's BIG2 outranks the
  -- species term so the trait keeps flowing in; the species term then favors
  -- X-carrier good-w drones over the donor as they appear.
  local BIG2 = BIG * BIG
  local function droneScore(g) return (goodW(g) and BIG2 or 0) + xFit(g) end
  local anyTrue = function() return true end
  local bestP = pickBest(true, function(g) return xAlleles(g) >= 1 end, xFit) or pickBest(true, anyTrue, fit)
  local bestD = pickBest(false, anyTrue, droneScore)
  if not bestP then return "perfect_need_princess:restock" end
  if not bestD then return "perfect_need_drone:restock" end
  local bestPs, bestDs = fit(bestP), fit(bestD)

  agent().select(bestP._slot)
  if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
  local dSlot = ensureSingleItemSlot(config, bestD._slot)
  if not dSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(dSlot)
  if not beekeeper().swapDrone(down) then return "swap_drone_failed" end
  return string.format("imprinting %s trait %d/%d (P%.0f x D%.0f)",
    site.targetSpecies, working, #opts.traitOrder, bestPs, bestDs)
end

-- Reclaim a drone stranded ALONE in an apiary's drone slot (slot 2). Forestry
-- consumes the drone when a princess becomes a queen, but live runs show drones
-- persisting in slot 2 with NO princess in slot 1 -- and M.harvestSite only pulls
-- the product slots (3+), while nothing anywhere else ever reads or clears slot 2.
-- A lone drone there can't mate (a wasted apiary cycle) and, worse, would mate
-- with the NEXT princess seeded into slot 1 before the intended drone is loaded
-- (a wrong cross). So whenever slot 1 is empty, pull any slot-2 drone back into
-- cargo, where it becomes a normal candidate again. No-op if slot 1 is occupied,
-- slot 2 is already empty, or cargo has no free slot to receive it.
function M.reclaimLoneDrone(config, site)
  local down = sides().down
  if invCtrl().getStackInSlot(down, 1) ~= nil then return false end -- princess/queen present
  if invCtrl().getStackInSlot(down, 2) == nil then return false end -- drone slot already clear
  local dest = nil
  for _, slot in ipairs(config.workingSlots) do
    if slot ~= config.honeySlot and invCtrl().getStackInInternalSlot(slot) == nil then
      dest = slot; break
    end
  end
  if not dest then return false end -- cargo full: leave it rather than lose it
  Status.setStep("Reclaiming stranded drone at " .. (site.name or "?"))
  agent().select(dest)
  return beekeeper().swapDrone(down) and true or false
end

-- Runs one decision+action cycle for a "traitmax" or "species" site.
-- Returns a short status string for logging.
function M.runQualitySite(config, site)
  Status.setStep("Heading to " .. (site.name or "?") .. " (" .. site.mode .. ")")
  local ok, reason = gotoSite(site)
  if not ok then return "nav_failed:" .. tostring(reason) end

  local down = sides().down
  local traitList = M.traitListFor(site.mode)
  local targetSpecies = site.targetSpecies

  if beekeeper().canWork(down) then
    local progress = beekeeper().getBeeProgress(down)
    -- getBeeProgress is what actually COMPLETES breeding on its final
    -- tick (consumes the queen, creates her offspring/output) -- if
    -- she's still there afterward, this visit's work genuinely isn't
    -- done yet, so report progress and leave. But if she's now GONE,
    -- breeding just finished on THIS call, and the apiary would
    -- otherwise sit idle for a whole extra cycle (robot leaves, has to
    -- come all the way back) before the seed+evaluate+load logic below
    -- ever runs again -- so fall through into it in this SAME visit
    -- instead, same principle as the earlier fix that stopped a
    -- princess being seeded without a drone loaded in the same visit.
    if M.readSideSlot(down, 1) ~= nil then
      return string.format("working (%.0f%%)", progress)
    end

    -- Breeding just completed -- her offspring/output is sitting in the
    -- apiary's product slots RIGHT NOW, not yet in cargo, and definitely
    -- not analyzed yet. Harvest and analyze it immediately, before
    -- falling through to seed+evaluate+load below, so it's actually
    -- available as a candidate for the very next pairing decision
    -- instead of sitting unanalyzed until some later, unrelated visit.
    M.harvestSite(config, site)
    M.analyzeWorkingSlots(config)
  end

  -- Clear any drone stranded alone in slot 2 BEFORE seeding a princess below --
  -- otherwise she'd mate with the leftover drone instead of the one we pick.
  M.reclaimLoneDrone(config, site)

  -- Never load a drone next to a bee that's already set up (see
  -- M.apiaryLoadGuard): a mated queen mid-cycle stays untouched even if
  -- canWork() momentarily reads false, and a princess already paired with a
  -- drone keeps that committed cross instead of getting a freshly re-picked
  -- (effectively random) drone every visit.
  local guarded = M.apiaryLoadGuard(down, site)
  if guarded then return guarded end

  local princessIndividual = M.readSideSlot(down, 1)
  local seededThisVisit = false
  if not princessIndividual then
    -- The apiary's queen slot is empty. This isn't necessarily "never
    -- had one" -- a spent queen is fully CONSUMED by Forestry once she
    -- finishes breeding, and her replacement offspring princess lands in
    -- the product/output area (confirmed via probeInventoryBelow()), NOT
    -- back in the queen slot. Nothing else in this file ever re-seeds a
    -- princess for traitmax/species sites (only the mutation flow calls
    -- swapQueen), so without this, a site goes permanently idle the
    -- moment its queen runs out.
    local princessSlot = findPrincessCandidate(config, traitList, targetSpecies)
    if not princessSlot then
      return "no_princess_at_site_or_in_cargo"
    end
    Status.setStep("Seeding princess into " .. (site.name or "?"))
    agent().select(princessSlot)
    if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
    -- Continue straight into drone evaluation/loading below, in this
    -- SAME visit, instead of leaving the apiary half set up (a princess
    -- but no drone) until whenever it happens to be revisited again --
    -- she's immediately readable back out via readSideSlot now that
    -- she's actually installed, nothing technical requires waiting for
    -- a separate cycle. This is what real-hardware watching caught:
    -- the robot visibly "abandoning" an apiary mid-setup to wander off
    -- elsewhere, only coming back to finish it much later (if a
    -- different site's turn didn't get there first).
    princessIndividual = M.readSideSlot(down, 1)
    if not princessIndividual then return "swap_queen_failed_readback" end
    seededThisVisit = true
  end

  Status.setStep("Evaluating drones for " .. (site.name or "?"))
  local princessBee = toBreedingBee("princess", princessIndividual, traitList, targetSpecies)

  -- Cache how close this apiary's princess is to purebred-perfect, for
  -- the dashboard. Stored on the site rather than passed around because
  -- an apiary's contents are a side-relative read -- only knowable while
  -- the drone is actually standing at it -- so this is a last-known
  -- value, refreshed each visit, not live telemetry.
  site.progress = M.purityOf(traitList, princessBee.genotype)
  local dronePool = gatherCandidateDrones(config, traitList, targetSpecies)
  if #dronePool == 0 then
    return seededThisVisit and "seeded princess (no drone candidates in cargo yet)"
      or "no_candidate_drones_in_working_slots"
  end

  local endgame = BB.isPhenotypicallyPerfect(traitList, princessBee.genotype)
  local plan = BB.planGeneration(traitList, princessBee.genotype, dronePool, {}, endgame,
    config.minCopies, Cfg.weights)

  if not plan.breedWith then
    return seededThisVisit and "seeded princess (no viable drone yet)" or "no_viable_drone"
  end

  -- Load the winning drone FIRST, while still standing right at the site
  -- -- no reason to make discarding the losers a detour in between
  -- deciding and actually finishing the setup. Discarding is handled
  -- afterward instead (see below): it doesn't need the winner loaded
  -- first, and putting it after means this apiary is fully set up
  -- (princess + drone both in) before the robot goes anywhere else, same
  -- principle as the earlier fix that stopped it seeding a princess and
  -- wandering off before loading a drone at all.
  Status.setStep("Loading drone into " .. (site.name or "?"))
  local droneSlot = ensureSingleItemSlot(config, plan.breedWith._slot)
  if not droneSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(droneSlot)
  local swapped = beekeeper().swapDrone(down)
  if not swapped then return "swap_drone_failed" end

  local discardCount = 0
  for _, entry in ipairs(plan.toDiscard) do
    if entry.drone.id ~= plan.breedWith.id then discardCount = discardCount + 1 end
  end

  -- Discard drones the plan doesn't want -- but ONLY when cargo is
  -- genuinely under space pressure. shouldBank's "redundant, no unique
  -- value" verdict is about GENETIC value relative to what's currently
  -- banked, not about whether there's room to spare -- discarding the
  -- instant something's judged redundant, even with plenty of free
  -- cargo, throws away genetic material for no reason: keeping it costs
  -- nothing when there's room, and minCopies math can shift as other
  -- drones get consumed elsewhere, potentially making it useful again
  -- later. Default behavior when actually discarding: M.dumpDiscards, which
  -- is BANK-GATED -- it preserves (routes to the storage network, keeping the
  -- genes) any bee whose species isn't banked to reserve yet, and only voids
  -- (config.trashPos, see M.dumpToTrash) the redundant byproducts of species
  -- that already have a full bank. Override config.onDiscard to route elsewhere
  -- entirely (sampler/furnace/junk). No trip back to the site afterward
  -- needed -- the apiary is already fully loaded, and wherever this
  -- discard trip ends is a perfectly fine place to start the next
  -- site's travel from.
  if discardCount > 0 then
    local freeSlots = 0
    for _, slot in ipairs(config.workingSlots) do
      if invCtrl().getStackInInternalSlot(slot) == nil then freeSlots = freeSlots + 1 end
    end
    if freeSlots < (config.minFreeSlotsBeforeDiscard or 3) then
      if config.onDiscard then
        for _, entry in ipairs(plan.toDiscard) do
          if entry.drone.id ~= plan.breedWith.id then config.onDiscard(entry.drone) end
        end
      else
        -- Bank-gated: an off-target loser (e.g. a Forest/Meadows drone while
        -- trait-maxing Mystical) is preserved in storage unless its species is
        -- already banked -- its genes are the only seed for that species' future
        -- bank. Only genuinely-redundant banked species get voided to trash.
        M.dumpDiscards(config, plan.toDiscard, plan.breedWith.id)
      end
    end
  end

  return string.format("%sloaded drone (score %.1f)", seededThisVisit and "seeded princess + " or "", plan.score)
end

-- ============================================================
-- Mutation mode
-- ============================================================
--
-- The mutation graph is NOT queried live -- a moving robot has no
-- bee_housing / tile_for_apiculture component (confirmed; only a
-- stationary OC Adapter next to an apiary does). Instead the whole GTNH
-- graph is dumped ONCE from such a setup (scripts/dump_bee_data.lua),
-- shipped as bee_mutations.dat, loaded at startup, and handed in as
-- config.mutationGraph (a built graph from bee_mutation_graph.build --
-- see M.loadMutationGraph / bee_keeper_manager_run.lua). All the tree
-- reasoning lives in the pure bee_mutation_graph module (MG); this file
-- only turns its plan into real swapQueen/swapDrone actions.
--
-- DIRECTION: a mutation recipe is an ORDERED pair -- allele1 = princess,
-- allele2 = drone (confirmed). We load the princess-species specimen into
-- the queen slot and the drone-species specimen into the drone slot, in
-- that exact order (correct if GTNH enforces direction; still fires if it
-- doesn't). This is why groupBySpecies keeps princess/drone lists
-- separate -- a mutation step needs a genuine princess of one named
-- species and a genuine drone of the other, not just "any two bees".

-- Groups the agent's working-slot bees by species name (Cfg.speciesKey),
-- keeping SEPARATE princess-capable and drone-capable lists per species.
-- Forestry doesn't care which NAMED species ends up as the princess vs
-- the drone in a mutation -- but it absolutely cares that the princess
-- slot gets an actual princess/queen item and the drone slot gets an
-- actual drone. Mixing both roles into one list per species (the old
-- behavior) could pick a DRONE as the "princess" candidate whenever it
-- happened to score best, which swapQueen then correctly rejects.
local function groupBySpecies(config)
  local bySpecies = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local individual = readIndividual(stack)
    if individual then
      local name = Cfg.speciesKey(individual.active.species)
      bySpecies[name] = bySpecies[name] or { princesses = {}, drones = {} }
      local entry = { slot = slot, individual = individual }
      if isPrincessOrQueenStack(stack) then
        table.insert(bySpecies[name].princesses, entry)
      elseif isDroneStack(stack) then
        table.insert(bySpecies[name].drones, entry)
      end
    end
  end
  return bySpecies
end

-- Picks the best-scoring specimen for a species using the ACTIVE quality
-- traits (no species target -- we already know the species matches).
local function bestOfSpecies(candidates, traitList)
  local best, bestScore = nil, -math.huge
  for _, c in ipairs(candidates) do
    local score = 0
    for _, t in ipairs(traitList) do
      if BB.traitState(Cfg.normalizeGenotype({ t }, c.individual.active, c.individual.inactive), t) == "GG" then
        score = score + 1
      end
    end
    if score > bestScore then
      bestScore = score
      best = c
    end
  end
  return best
end

-- The set of species names the agent can SUSTAINABLY supply -- the "owned"
-- boundary the tree planner stops at (already-obtained intermediates don't
-- need re-breeding). Ownership is by PRINCESS/queen, not just any specimen:
-- a princess, when bred, regenerates both a replacement princess AND drones
-- of her species indefinitely, so holding one means you can supply that
-- species in either role forever. Drone-ONLY stock can't: a drone's
-- offspring take the OTHER parent's species, so drones get consumed without
-- ever yielding a princess of their own species. Counting a drone-only
-- species as "owned" strands the planner -- it stops breeding that
-- intermediate, so the princess a downstream step needs (allele1) never
-- materializes (a real, reproducible deadlock: Common-as-drone-only blocks
-- Cultivated = Common(princess) x Forest forever). Requiring a princess
-- keeps the robot breeding an intermediate until it has a usable one.
-- (Base leaves the user must gather aren't tracked here at all -- the graph
-- treats them as acquirable; the executor's per-recipe check gates whether
-- the specific princess/drone roles are actually in cargo.)
function M.ownedSpecies(config)
  local owned = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if isPrincessOrQueenStack(stack) then
      local individual = readIndividual(stack)
      if individual and individual.active and individual.active.species then
        owned[Cfg.speciesKey(individual.active.species)] = true
      end
    end
  end
  return owned
end

-- Plans the NEXT actionable mutation step toward targetSpecies, given
-- what's currently in cargo. Delegates the whole tree search to the pure
-- bee_mutation_graph module (min-cost AND-OR fixpoint over the real GTNH
-- graph), then resolves the FIRST step of the returned topological plan
-- to concrete cargo slots.
--
-- Why the first step is always the right one to act on: MG.traverseTree
-- emits steps post-order and stops at owned species, so steps[1]'s two
-- parents are each either already owned or a missing base leaf -- nothing
-- earlier needs breeding first. As each intermediate gets bred and shows
-- up in cargo, ownedSpecies grows and the plan naturally advances to the
-- next step on a later visit (the tree is re-planned every cycle from
-- live cargo, so it self-corrects if a bee is lost).
--
-- Returns (step, nil) on success, where step is
--   { princessSlot, droneSlot, princessSpecies, droneSpecies, chance,
--     conditions, subTarget, missingLeaves }
-- or (nil, reportString) when nothing's actionable yet -- the report
-- names exactly what's missing (a role of a held species, or which base
-- leaf bees the user still has to go gather).
function M.planMutationStep(config, targetSpecies, traitList)
  local graph = config.mutationGraph
  if not graph then return nil, "no_mutation_graph_loaded" end

  local owned = M.ownedSpecies(config)
  local plan = MG.planBreedingTree(graph, owned, targetSpecies)
  if plan.alreadyOwned then return nil, "already_have_target" end
  if not plan.reachable then
    local report = "target '" .. tostring(targetSpecies) .. "' is unreachable from the known mutation graph"
    return nil, report
  end
  if #plan.steps == 0 then return nil, "no_actionable_step" end

  -- The plan names ONE recipe per intermediate, but many species have
  -- several recipes (Common = Forest x {Wintry, Meadows, Tropical, ...}).
  -- The planner picks the graph-cheapest, which can name a parent the user
  -- doesn't currently hold even though a DIFFERENT recipe for the same
  -- result IS satisfiable from what's in cargo right now. So don't lock
  -- onto the planner's single choice: search ALL recipes producing this
  -- sub-target and use whichever is actually satisfiable (directionally)
  -- with the drones/princesses on hand -- "find another available drone if
  -- one exists". Rank satisfiable recipes by least special-condition
  -- burden, then highest chance (the planner's own priority order).
  local step = plan.steps[1]
  local held = groupBySpecies(config)

  -- Satisfiability of a recipe from current stock: a genuine princess/queen of
  -- the allele1 species and a genuine drone of the allele2 species. (Genebank
  -- mode uses the bee_genebank_scheduler path instead of this planner.)
  local function satisfiable(r)
    local pg, dg = held[r.princess], held[r.drone]
    return pg and #pg.princesses > 0 and dg and #dg.drones > 0
  end

  -- DIRECTIONAL throughout: princess must be a genuine princess/queen item
  -- of allele1, drone a genuine drone item of allele2 -- never the reverse.
  local candidates = graph.byResult[step.result] or {
    { princess = step.princess, drone = step.drone, chance = step.chance,
      conditions = step.conditions, condCost = 0 },
  }
  local best = nil
  for _, r in ipairs(candidates) do
    if satisfiable(r) then
      if not best
        or (r.condCost or 0) < (best.condCost or 0)
        or ((r.condCost or 0) == (best.condCost or 0) and (r.chance or 0) > (best.chance or 0)) then
        best = r
      end
    end
  end

  if not best then
    -- No recipe for this sub-target is satisfiable from cargo yet -- report
    -- what the planner's chosen (cheapest) recipe needs, plus any base leaf
    -- bees the user must go gather for the whole tree.
    local needs = {}
    local pGroup, dGroup = held[step.princess], held[step.drone]
    if not (pGroup and #pGroup.princesses > 0) then
      table.insert(needs, string.format("a princess/queen of '%s'", step.princess))
    end
    if not (dGroup and #dGroup.drones > 0) then
      table.insert(needs, string.format("a drone of '%s'", step.drone))
    end
    local report = string.format("to breed '%s' need %s", step.result, table.concat(needs, " and "))
    if plan.missingLeaves and #plan.missingLeaves > 0 then
      report = report .. "; missing base leaf bees to gather: " .. table.concat(plan.missingLeaves, ", ")
    end
    return nil, report
  end

  local princessPick = bestOfSpecies(held[best.princess].princesses, traitList)
  local dronePick = bestOfSpecies(held[best.drone].drones, traitList)
  return {
    princessSlot = princessPick.slot,
    droneSlot = dronePick.slot,
    princessSpecies = best.princess,
    droneSpecies = best.drone,
    chance = best.chance,
    conditions = best.conditions or {},
    subTarget = step.result,
    missingLeaves = plan.missingLeaves,
  }, nil
end

-- Two rising beeps -- the audible cue for the special-condition gate
-- (see M.gateSpecialConditions). Guarded: a host without a beep-capable
-- computer just no-ops instead of erroring.
function M.beepAlert()
  pcall(function()
    local computer = require("computer")
    if computer.beep then
      computer.beep(1000, 0.2)
      computer.beep(1400, 0.2)
    end
  end)
end

-- Gate before a mutation step whose recipe carries special conditions the
-- robot can't provide itself (a foundation block, a biome/dimension, a
-- climate, a time window -- see bee_mutation_graph's condition classes).
-- Returns true when the step may proceed, false to defer it this cycle.
--
-- config.confirmCondition(conditions, subTarget) -> bool overrides the
-- behavior entirely (the simulator and headless tests inject one so a
-- multi-step tree with N confirmations runs instantly). With no override,
-- the real-hardware default beeps, prints the exact requirement strings,
-- and blocks on computer.pullSignal() until the user has set it up and
-- pokes the robot (any key/interrupt), then proceeds.
function M.gateSpecialConditions(config, conditions, subTarget)
  if not conditions or #conditions == 0 then return true end
  if config.confirmCondition then
    return config.confirmCondition(conditions, subTarget) and true or false
  end
  M.beepAlert()
  print(string.format("[special condition] Breeding '%s' needs manual setup:", tostring(subTarget)))
  for _, c in ipairs(conditions) do print("   - " .. tostring(c)) end
  print("   Set it up, then press any key / poke the robot to continue...")
  pcall(function() require("computer").pullSignal() end)
  return true
end

-- ============================================================
-- Genebank: per-species purebred reserves (see bee_genebank.lua). Opt-in via
-- config.genebank (a settings table, e.g. { minPrincesses=1, minDrones=8 }).
-- When absent, mutation mode behaves exactly as before (no reserve gating).
-- ============================================================

-- Is this individual homozygous (GG) for `species` on the species locus? The
-- "purebred" test the reserve counts on (quality-trait purity is separate).
function M.isSpeciesPurebred(individual, species)
  if not (individual and individual.active and individual.inactive) then return false end
  local g = Cfg.normalizeGenotype({ "species" }, individual.active, individual.inactive, species)
  return BB.traitState(g, "species") == "GG"
end

-- DEPRECATED / NO LONGER WIRED IN (kept for reference -- do NOT re-add to the
-- genebank loop). It junked ALL hybrid drones every cycle, which the cargo-resident
-- redesign (v0.5.7/0.5.8) needs as `fix`-job carrier fodder; it forced a storage
-- round-trip per cycle and left the lazy census stale. Cargo bounding is now done
-- by M.offloadSurplus (pressure-gated, cache-refreshing). See the note at the
-- runMutationSite genebank branch for the full rationale.
--
-- Junk the useless hybrid (non-purebred) byproducts of mutation crosses so they
-- don't pile up and crowd the banks out of cargo. What's junked:
--   * every hybrid DRONE (pure fodder -- breeding it drifts a bank), and
--   * IGNOBLE hybrid princesses (isNatural == false) -- bred princesses that
--     degrade and would otherwise accumulate forever.
-- What is NEVER junked: PRISTINE princesses (isNatural ~= false) -- scarce,
-- renewable breeding stock the whole program depends on -- and all purebred
-- bees (the banks). Purebred bees and pristine princesses always survive.
function M.junkHybrids(config, site)
  local entries = {}
  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    local ind = readIndividual(stack)
    if ind and ind.active and ind.active.species
      and (isDroneStack(stack) or isPrincessOrQueenStack(stack)) then
      local species = Cfg.speciesKey(ind.active.species)
      if not M.isSpeciesPurebred(ind, species) then
        local junk = isDroneStack(stack) or (ind.isNatural == false)
        if junk then table.insert(entries, { drone = { id = "hybrid:" .. slot, _slot = slot } }) end
      end
    end
  end
  if #entries == 0 then return 0 end
  -- Bank-gated: a hybrid drone of a species without a full bank yet is that
  -- species' only genetic seed -- preserve it in storage rather than void it.
  -- Only species already banked to reserve have their redundant byproducts
  -- trashed here. (Was: trash-preferred, which voided un-banked base species.)
  return M.dumpDiscards(config, entries, nil)
end

-- ============================================================
-- Storage-backed genebank: BANKS LIVE IN THE STORAGE CHEST; cargo is a transient
-- working buffer. Each visit deposits cargo bees into storage, scans the full
-- stock there, lets the scheduler pick a job, fetches just that job's two parents
-- back into cargo, and breeds them at the apiary. So cargo can never overflow and
-- the scheduler always sees the complete stock -- what makes deep trees (and
-- rainbow scale) actually work, instead of being blind to bees sitting in storage.
-- ============================================================

-- Classify a stack: { species, role="princess"|"drone", pure, alleles } or nil.
local function classifyBee(stack)
  local ind = readIndividual(stack)
  if not (ind and ind.active and ind.active.species and ind.inactive and ind.inactive.species) then
    return nil
  end
  local role = isPrincessOrQueenStack(stack) and "princess"
    or (isDroneStack(stack) and "drone" or nil)
  if not role then return nil end
  local a = Cfg.speciesKey(ind.active.species)
  local i = Cfg.speciesKey(ind.inactive.species)
  return { species = a, role = role, pure = (a == i), alleles = { [a] = true, [i] = true }, size = stack.size or 1 }
end

-- Deposits every bee currently in cargo into the STORAGE NETWORK (all
-- config.storagePositions, spilling store to store), then scans the WHOLE network
-- for the genebank census. Leaves the robot at the last store visited. Returns:
--   summary     = { [species] = { purePrincesses, pureDrones } }
--   convertible = { [species] = <# pristine hybrid princesses carrying that allele> }
--   slotsByKey  = fetch index: "P:<sp>" pure princess, "D:<sp>" pure drone,
--                 "V:<sp>" hybrid vessel carrying <sp> -> { {pos=<storeIndex>, slot}, ... }
-- A census accumulator: classifies bee stacks into per-species bank counts.
-- Shared by the storage scan (M.scanStorageCensus) and the live cargo read
-- (M.cargoCensus) so both emit the identical { summary, convertible, slotsByKey }
-- shape the scheduler + fetch index consume. `loc` tags where each slot lives --
-- a storage-position index, or the string "cargo" -- so the executor can tell a
-- resident (already-in-cargo) parent from one that must be fetched from storage.
local function newCensus()
  local c = { summary = {}, convertible = {}, convertibleDrones = {}, slotsByKey = {} }
  local function rec(sp)
    c.summary[sp] = c.summary[sp] or { purePrincesses = 0, pureDrones = 0 }
    return c.summary[sp]
  end
  local function addSlot(key, loc, slot)
    c.slotsByKey[key] = c.slotsByKey[key] or {}
    table.insert(c.slotsByKey[key], { pos = loc, slot = slot })
  end
  function c.add(loc, slot, stack)
    local bee = classifyBee(stack)
    if not bee then return end
    if bee.role == "princess" and bee.pure then
      rec(bee.species).purePrincesses = rec(bee.species).purePrincesses + bee.size
      addSlot("P:" .. bee.species, loc, slot)
    elseif bee.role == "princess" then -- hybrid: carrier fodder toward either allele
      for allele in pairs(bee.alleles) do
        c.convertible[allele] = (c.convertible[allele] or 0) + bee.size
        addSlot("V:" .. allele, loc, slot)
      end
    elseif bee.role == "drone" and bee.pure then
      rec(bee.species).pureDrones = rec(bee.species).pureDrones + bee.size
      addSlot("D:" .. bee.species, loc, slot)
    elseif bee.role == "drone" then -- hybrid DRONE: carrier fodder for consolidation
      -- Tracked (was ignored): a mutation yields hybrid drones too, and breeding
      -- a carrier princess x carrier drone of the same allele is the ONLY way to
      -- bootstrap the first PURE of a mutated species (~25% pure offspring).
      for allele in pairs(bee.alleles) do
        c.convertibleDrones[allele] = (c.convertibleDrones[allele] or 0) + bee.size
        addSlot("W:" .. allele, loc, slot)
      end
    end
  end
  return c
end

-- Scan-ONLY census of the whole storage network (no deposit). Flies to each
-- store. Refreshes config._bankCensus (the cache the lazy loop trusts between
-- storage visits) + config._bankConvertible. Returns summary, convertible,
-- slotsByKey (entries {pos=<storeIndex>, slot}).
function M.scanStorageCensus(config)
  if #M.storagePositions(config) == 0 then return {}, {}, {}, {} end
  local c = newCensus()
  M.forEachStorageStack(config, function(pos, slot, stack) c.add(pos, slot, stack) end, "Scanning storage")
  config._bankCensus = c.summary
  config._bankConvertible = c.convertible
  config._bankConvertibleDrones = c.convertibleDrones
  config._bankSlotsByKey = c.slotsByKey
  return c.summary, c.convertible, c.slotsByKey, c.convertibleDrones
end

-- Live census of what's ALREADY in cargo -- free (no travel). Same shape as the
-- storage scan, but slotsByKey entries are tagged pos="cargo" so the executor
-- knows those parents are resident and need no fetch. Excludes the honey slot.
function M.cargoCensus(config)
  local c = newCensus()
  for _, cslot in ipairs(config.workingSlots) do
    if cslot ~= config.honeySlot then
      c.add("cargo", cslot, invCtrl().getStackInInternalSlot(cslot))
    end
  end
  return c.summary, c.convertible, c.slotsByKey, c.convertibleDrones
end

-- INCREMENTAL CENSUS: keep the cached storage census consistent with a SINGLE
-- deposit or fetch, so a storage trip no longer has to re-sweep every store to
-- refresh it. `size` units of `stack` were added to (removing=false) or removed
-- from (removing=true) storage slot (loc, slot); nowEmpty says the slot is empty
-- after a removal. Mirrors newCensus.add's bucketing exactly, so the running
-- cache stays byte-identical to a fresh M.scanStorageCensus (asserted in
-- bee_keeper_census_test.lua). No-op if the cache isn't seeded yet -- the first
-- full scan builds it, and a periodic full re-scan self-heals any missed delta.
function M.censusApplyStack(config, loc, slot, stack, size, removing, nowEmpty)
  if not config._bankCensus then return end
  local bee = classifyBee(stack)
  if not bee or not size or size <= 0 then return end
  config._bankConvertible = config._bankConvertible or {}
  config._bankConvertibleDrones = config._bankConvertibleDrones or {}
  config._bankSlotsByKey = config._bankSlotsByKey or {}
  local d = removing and -size or size

  local keys
  if bee.role == "princess" and bee.pure then
    local rec = config._bankCensus[bee.species] or { purePrincesses = 0, pureDrones = 0 }
    rec.purePrincesses = math.max(0, rec.purePrincesses + d); config._bankCensus[bee.species] = rec
    keys = { "P:" .. bee.species }
  elseif bee.role == "drone" and bee.pure then
    local rec = config._bankCensus[bee.species] or { purePrincesses = 0, pureDrones = 0 }
    rec.pureDrones = math.max(0, rec.pureDrones + d); config._bankCensus[bee.species] = rec
    keys = { "D:" .. bee.species }
  elseif bee.role == "princess" then
    keys = {}
    for a in pairs(bee.alleles) do
      config._bankConvertible[a] = math.max(0, (config._bankConvertible[a] or 0) + d)
      keys[#keys + 1] = "V:" .. a
    end
  else
    keys = {}
    for a in pairs(bee.alleles) do
      config._bankConvertibleDrones[a] = math.max(0, (config._bankConvertibleDrones[a] or 0) + d)
      keys[#keys + 1] = "W:" .. a
    end
  end

  -- Reconcile slotsByKey entries for this exact (loc, slot): add on deposit (if
  -- not already present -- a merge into an existing stack keeps one entry), drop
  -- on a removal that emptied the slot.
  for _, key in ipairs(keys) do
    local list = config._bankSlotsByKey[key]
    if not list then list = {}; config._bankSlotsByKey[key] = list end
    local found = false
    for i = #list, 1, -1 do
      if list[i].pos == loc and list[i].slot == slot then
        found = true
        if removing and nowEmpty then table.remove(list, i) end
      end
    end
    if not removing and not found then list[#list + 1] = { pos = loc, slot = slot } end
  end
end

-- Pure: sum two census summaries ({ [sp]={purePrincesses,pureDrones} }) into a
-- new one. Used to give the scheduler the TOTAL available view (cached storage
-- census + live cargo) without re-scanning storage.
function M.mergeCensus(a, b)
  local out = {}
  local function fold(src)
    for sp, s in pairs(src or {}) do
      out[sp] = out[sp] or { purePrincesses = 0, pureDrones = 0 }
      out[sp].purePrincesses = out[sp].purePrincesses + (s.purePrincesses or 0)
      out[sp].pureDrones = out[sp].pureDrones + (s.pureDrones or 0)
    end
  end
  fold(a); fold(b)
  return out
end

-- Pure: sum two convertible maps ({ [sp]=count }).
function M.mergeConvertible(a, b)
  local out = {}
  for sp, n in pairs(a or {}) do out[sp] = (out[sp] or 0) + n end
  for sp, n in pairs(b or {}) do out[sp] = (out[sp] or 0) + n end
  return out
end

-- Pure: merge fetch indices ({ key -> { {pos,slot}, ... } }), concatenating the
-- entry lists. Order doesn't matter -- fetchJobParents.pick() prefers a
-- pos="cargo" entry regardless of position.
function M.mergeSlotsByKey(...)
  local out = {}
  for _, src in ipairs({ ... }) do
    for k, list in pairs(src or {}) do
      out[k] = out[k] or {}
      for _, e in ipairs(list) do out[k][#out[k] + 1] = e end
    end
  end
  return out
end

-- Empty working slots available for new bees (excludes the honey slot). Drives
-- the "cargo too full to extract -> offload" decision.
function M.cargoFreeSlots(config)
  local n = 0
  for _, cslot in ipairs(config.workingSlots) do
    if cslot ~= config.honeySlot and invCtrl().getStackInInternalSlot(cslot) == nil then
      n = n + 1
    end
  end
  return n
end

-- The resident PRINCESS target: enough to feed every apiary in one pass, but
-- never more than half the usable cargo (the other half is for donor drone
-- stacks + offspring extraction). min(#apiaries, floor(usable/2)), at least 1.
function M.residentPrincessTarget(config)
  local usable = #config.workingSlots - (config.honeySlot and 1 or 0)
  local byCargo = math.floor(usable / 2)
  local byApiaries = #(config.sites or {})
  return math.max(1, math.min(byApiaries > 0 and byApiaries or byCargo, byCargo))
end

-- Deposit SURPLUS cargo bees to storage (genes kept) ONLY when cargo is too full
-- to extract offspring -- the pressure valve for the cargo-resident loop. Keeps a
-- working set resident: up to residentPrincessTarget princesses, plus the biggest
-- drone stacks (config.workingDroneStacks, so the current donor stack -- the one
-- just fetched at 64 -- stays for probabilistic retries); everything beyond that
-- is deposited. Never trashes; the whole point is to preserve, just off-cargo.
-- Returns the number deposited.
-- Census keys a cargo bee would occupy (mirrors newCensus.add), used to tell
-- whether a bee is one of the CURRENT job's parents.
local function beeCensusKeys(bee)
  if bee.role == "princess" and bee.pure then return { "P:" .. bee.species } end
  if bee.role == "princess" then
    local k = {}; for a in pairs(bee.alleles) do k[#k + 1] = "V:" .. a end; return k
  end
  if bee.role == "drone" and bee.pure then return { "D:" .. bee.species } end
  local k = {}; for a in pairs(bee.alleles) do k[#k + 1] = "W:" .. a end; return k
end

function M.offloadSurplus(config, protectKeys)
  local reserve = config.extractReserve or 3
  if M.cargoFreeSlots(config) >= reserve then return 0 end -- not pressured
  protectKeys = protectKeys or {}

  -- Is this bee one of the current job's parents (by census key)? Kept resident
  -- FIRST so consecutive fix/seed attempts breed straight from cargo instead of
  -- re-fetching the same carriers from storage every cycle (the storage-thrash).
  local function isProtected(bee)
    for _, key in ipairs(beeCensusKeys(bee)) do if protectKeys[key] then return true end end
    return false
  end

  local princesses, drones = {}, {}
  for _, cslot in ipairs(config.workingSlots) do
    if cslot ~= config.honeySlot then
      local bee = classifyBee(invCtrl().getStackInInternalSlot(cslot))
      if bee then
        local rec = { slot = cslot, size = bee.size, protected = isProtected(bee) }
        if bee.role == "princess" then princesses[#princesses + 1] = rec
        elseif bee.role == "drone" then drones[#drones + 1] = rec end
      end
    end
  end
  -- Keep the job's parents first, then the LARGEST stacks (the fetched 64-donor
  -- sticks around); shed unprotected, smaller piles first.
  local function keepRank(x, y)
    if x.protected ~= y.protected then return x.protected end -- protected first
    return x.size > y.size
  end
  table.sort(princesses, keepRank)
  table.sort(drones, keepRank)

  local keepP = M.residentPrincessTarget(config)
  local keepD = config.workingDroneStacks or 4
  local toDeposit = {}
  for i, p in ipairs(princesses) do
    if i > keepP then toDeposit[#toDeposit + 1] = { _slot = p.slot } end
  end
  for i, d in ipairs(drones) do
    if i > keepD then toDeposit[#toDeposit + 1] = { _slot = d.slot } end
  end
  if #toDeposit == 0 then return 0 end

  Status.setStep(string.format("Offloading %d surplus bee(s) to storage", #toDeposit))
  local dropped, pending = M.depositBeesAcrossStores(config, toDeposit)
  if #pending > 0 then M.onStorageFull(config, pending) end
  return dropped
end

-- Deposit ALL cargo bees into the network, then re-scan. The heavy full-sync
-- (a storage round trip every call) -- kept for the offload path and any caller
-- that wants the banks flushed. The lazy genebank loop no longer calls this every
-- cycle; it breeds from the resident working set and only offloads under cargo
-- pressure (see M.offloadSurplus).
function M.syncBanksToStorage(config)
  if #M.storagePositions(config) == 0 then return {}, {}, {} end
  local entries = {}
  for _, cslot in ipairs(config.workingSlots) do
    if classifyBee(invCtrl().getStackInInternalSlot(cslot)) then
      entries[#entries + 1] = { _slot = cslot }
    end
  end
  if #entries > 0 then
    local _, pending = M.depositBeesAcrossStores(config, entries)
    if #pending > 0 then M.onStorageFull(config, pending) end
  end
  return M.scanStorageCensus(config)
end

-- Pull one bee named by `entry` ({ pos = <storeIndex>, slot }) into a free cargo
-- slot, flying to that store first (the census spans the whole network, so the
-- bee may be in a different store than the robot currently sits at). Returns true
-- on success.
local function fetchOne(config, entry, count)
  count = count or 1
  -- Already resident in cargo (census tagged it pos="cargo") -> no fetch needed.
  if entry.pos == "cargo" then return true end
  local down = sides().down
  local free
  for _, cslot in ipairs(config.workingSlots) do
    if cslot ~= config.honeySlot and invCtrl().getStackInInternalSlot(cslot) == nil then free = cslot; break end
  end
  if not free then return false end
  local pos = M.storagePositions(config)[entry.pos]
  if not pos then return false end
  if not Nav.gotoXZ(pos.x, pos.z) then return false end
  local before = invCtrl().getStackInSlot(down, entry.slot) -- for the incremental census delta
  agent().select(free)
  local moved = invCtrl().suckFromSlot(down, entry.slot, count)
  if moved and moved > 0 then
    if before then
      M.censusApplyStack(config, entry.pos, entry.slot, before, moved, true, moved >= (before.size or 1))
    end
    return true
  end
  return false
end

-- What a job needs as parents, in one place: the census-key + selection criteria
-- for the princess (a PURE species, or a hybrid VESSEL carrying an allele) and
-- for the drone (a pure species). Drives the fetch index, the residency check,
-- and the in-cargo parent selection alike.
local function jobParentSpec(job)
  if job.type == "mutate" then
    return { pKey = "P:" .. job.princess, pSpecies = job.princess, pVessel = false,
             dKey = "D:" .. job.drone, dSpecies = job.drone }
  elseif job.type == "grow" then
    return { pKey = "P:" .. job.species, pSpecies = job.species, pVessel = false,
             dKey = "D:" .. job.species, dSpecies = job.species }
  elseif job.type == "convert" then
    return { pKey = "V:" .. job.to, pAllele = job.to, pVessel = true,
             dKey = "D:" .. job.to, dSpecies = job.to }
  elseif job.type == "fix" then
    -- Consolidate carriers into a PURE: a hybrid princess carrying the allele
    -- (V:) crossed with a hybrid DRONE carrying it (W:) -> ~25% pure offspring.
    return { pKey = "V:" .. job.species, pAllele = job.species, pVessel = true,
             dKey = "W:" .. job.species, dSpecies = job.species, dVessel = true }
  elseif job.type == "seedDrone" then
    -- Spread the species-allele into the DRONE pool: a carrier PRINCESS of X (V:)
    -- x a PURE PARENT drone -> ~50% carrier drones (W:X), so `fix` can then run.
    return { pKey = "V:" .. job.species, pAllele = job.species, pVessel = true,
             dKey = "D:" .. job.drone, dSpecies = job.drone }
  elseif job.type == "seedPrincess" then
    -- Spread the species-allele into the PRINCESS pool: a PURE PARENT princess x a
    -- carrier DRONE of X (W:) -> ~50% carrier princesses (V:X), so `fix` can run.
    return { pKey = "P:" .. job.princess, pSpecies = job.princess, pVessel = false,
             dKey = "W:" .. job.species, dSpecies = job.species, dVessel = true }
  end
  return nil
end

-- Are BOTH of a job's parents already resident in cargo? (cargoKeys is the
-- cargo-only census index.) If so the whole breeding attempt runs with no storage
-- trip.
local function jobParentsResident(job, cargoKeys)
  local spec = jobParentSpec(job)
  if not spec then return false end
  local function has(k) local l = cargoKeys[k]; return l and #l > 0 end
  return has(spec.pKey) and has(spec.dKey)
end

-- Fetch a job's two parents into cargo. slotsByKey entries may point at storage
-- (fly + suck) or at a cargo-resident stack (no-op) -- fetchOne handles both, and
-- pick() prefers a resident source. The DRONE is pulled as a full STACK
-- (config.fetchDroneStack, 64 by default) so repeated probabilistic mutation
-- attempts run straight from cargo without another storage trip; the princess
-- (one spent per mating) is pulled singly. Returns (true) or (false, reason).
local function fetchJobParents(config, job, slotsByKey)
  local spec = jobParentSpec(job)
  if not spec then return false, "unknown_job_type" end
  local function pick(key)
    local l = slotsByKey[key]
    if not l or #l == 0 then return nil end
    for _, e in ipairs(l) do if e.pos == "cargo" then return e end end -- prefer resident
    return l[1]
  end
  local a, b = pick(spec.pKey), pick(spec.dKey)
  if not a then return false, "no " .. spec.pKey end
  if not b then return false, "no " .. spec.dKey end
  Status.setStep(string.format("Fetching %s + %s from storage", spec.pKey, spec.dKey))
  if not fetchOne(config, a, 1) then return false, "pull " .. spec.pKey end
  if not fetchOne(config, b, config.fetchDroneStack or 64) then return false, "pull " .. spec.dKey end
  return true
end

-- Special conditions attached to the recipe that produces `result` in the plan.
local function conditionsForResult(plan, result)
  for _, step in ipairs(plan.steps) do
    if step.result == result then return step.conditions end
  end
  return nil
end

-- Does a cargo bee satisfy the job's princess / drone requirement? SPECIES-aware
-- (cargo now holds a resident working set of many species, not just the fetched
-- pair) -- a pure requirement matches a purebred of that species; a vessel
-- requirement matches any carrier of the allele.
local function princessMatches(bee, spec)
  if spec.pVessel then return bee.alleles[spec.pAllele] == true end
  return bee.pure and bee.species == spec.pSpecies
end
local function droneMatches(bee, spec)
  if spec.dVessel then return bee.alleles[spec.dSpecies] == true end
  return bee.pure and bee.species == spec.dSpecies
end

-- Loads the job's two parents from cargo into the apiary and breeds them. Selects
-- the SPECIFIC princess/drone the job wants (by species/allele) out of whatever
-- resident working set cargo currently holds.
-- Which species a job is ultimately building toward -- so parent selection can
-- score candidates by how close they are to that pure target genome.
local function jobTargetSpecies(job)
  return job.species or job.to or job.result
end

local function executeJobAtApiary(config, site, job)
  local down = sides().down
  local spec = jobParentSpec(job)
  if not spec then return "unknown_job_type" end

  -- Announce WHAT this apiary visit is doing (the scheduler's job), so the
  -- dashboard shows "Fixing carriers into pure Common" etc. instead of leaving
  -- Nav's stale "Walking to (x,z)" up while it loads the pair.
  local jobSteps = {
    grow = "Growing " .. tostring(job.species) .. " drone bank",
    convert = "Converting a hybrid toward " .. tostring(job.to),
    fix = "Fixing carriers into pure " .. tostring(job.species),
    seedDrone = "Seeding " .. tostring(job.species) .. " carrier drones",
    seedPrincess = "Seeding " .. tostring(job.species) .. " carrier princesses",
    mutate = "Mutating " .. tostring(job.princess) .. " x " .. tostring(job.drone)
      .. (job.result and (" -> " .. tostring(job.result)) or ""),
  }
  if jobSteps[job.type] then Status.setStep(jobSteps[job.type] .. " at " .. (site.name or "?")) end

  -- GREEDY, FERTILITY-AWARE parent selection (the user's rule: breed the parent
  -- matching the most target slots -- species AND stats -- not the first found).
  -- Among the resident candidates that satisfy the job's role spec, pick the
  -- princess closest to the pure target genome, then the drone that best
  -- COMPLEMENTS her (bee_breeding.selectBestDrone), with species weighted high
  -- so consolidation never trades away species purity for a stat. Reuses the
  -- same scoring the quality phase uses, so a mutated species is solidified
  -- with good fertility instead of converging to a pure-but-fertility-1 dead bee.
  local tgt = jobTargetSpecies(job)
  local traitList = M.traitListFor(site.mode)
  local princesses, drones = {}, {}
  for _, cslot in ipairs(config.workingSlots) do
    if cslot ~= config.honeySlot then
      local stack = invCtrl().getStackInInternalSlot(cslot)
      local bee = classifyBee(stack)
      local ind = bee and readIndividual(stack)
      if bee and ind then
        local genotype = Cfg.normalizeGenotype(traitList, ind.active, ind.inactive, tgt)
        if bee.role == "princess" and princessMatches(bee, spec) then
          princesses[#princesses + 1] = { _slot = cslot, genotype = genotype }
        elseif bee.role == "drone" and droneMatches(bee, spec) then
          drones[#drones + 1] = { id = "slot" .. cslot, _slot = cslot, genotype = genotype }
        end
      end
    end
  end
  if #princesses == 0 or #drones == 0 then return "job_parents_missing_in_cargo" end

  table.sort(princesses, function(a, b)
    return M.purityOf(traitList, a.genotype) > M.purityOf(traitList, b.genotype)
  end)
  local pSlot = princesses[1]._slot
  local bestDrone = BB.selectBestDrone(traitList, princesses[1].genotype, drones, false, { species = 100 })
  local dSlot = bestDrone and bestDrone._slot
  if not pSlot or not dSlot then return "job_parents_missing_in_cargo" end

  agent().select(pSlot)
  if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
  dSlot = ensureSingleItemSlot(config, dSlot)
  if not dSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(dSlot)
  if not beekeeper().swapDrone(down) then return "swap_drone_failed" end

  if job.type == "grow" then return "growing " .. job.species .. " bank" end
  if job.type == "convert" then return "converting toward " .. job.to end
  if job.type == "fix" then return "fixing carriers into pure " .. job.species end
  if job.type == "seedDrone" then return "seeding " .. job.species .. " carrier drones (x pure " .. job.drone .. ")" end
  if job.type == "seedPrincess" then return "seeding " .. job.species .. " carrier princesses (pure " .. job.princess .. " x)" end
  local toward = (job.result ~= site.targetSpecies) and (" toward " .. job.result) or ""
  return "mutating " .. job.princess .. " x " .. job.drone .. toward
end

-- Assembles the scheduler state from the storage scan + the mutation graph, for
-- the given `target` species. Base species = graph LEAVES we actually hold (so
-- the plan never routes through a breeder we lack; a missing one surfaces as
-- "blocked: need pristine X").
function M.buildSchedulerState(config, site, summary, convertible, target, convertibleDrones)
  local graph = config.mutationGraph
  local opts = config.genebank
  local base = {}
  for sp in pairs(summary) do
    if (graph.leaves or {})[sp] then base[sp] = true end
  end
  local plan = MG.planBreedingTree(graph, base, target)
  local banks = {}
  for sp, s in pairs(summary) do
    banks[sp] = { purePrincesses = s.purePrincesses, pureDrones = s.pureDrones }
  end
  local state = {
    banks = banks, convertible = convertible, convertibleDrones = convertibleDrones or {},
    steps = plan.steps, baseSpecies = base, target = target,
    minPrincesses = GB.minPrincesses(opts), minDrones = GB.minDrones(opts),
    recoveryDrones = GB.recoveryDrones(opts),
  }
  return state, plan
end

-- RAINBOW: the next species to obtain a purebred bank of, given current banks
-- (from the storage summary). nil when every reachable species is banked.
local function rainbowTarget(config, summary)
  local graph = config.mutationGraph
  local ownedLeaves, banked = {}, {}
  for sp, s in pairs(summary) do
    if (graph.leaves or {})[sp] then ownedLeaves[sp] = true end
    if (s.purePrincesses or 0) >= 1 then banked[sp] = true end
  end
  local targetSet = Rainbow.targetSet(graph, ownedLeaves, config.rainbowTargetProvider)
  return Rainbow.nextTarget(graph, ownedLeaves, banked, targetSet),
    Rainbow.remaining(banked, targetSet)
end

-- TRAITMAX Phase A: the next DONOR species to bank a purebred of. The donor set
-- is chosen so the donors' default templates collectively supply a good allele
-- for every coverable target trait (bee_traitmax.plan). nil when every donor is
-- banked -> Phase A done, the site moves to the combine phase. Also returns the
-- plan (for surfacing uncoverable traits to the user).
local function traitmaxTarget(config, summary)
  local graph = config.mutationGraph
  local ownedLeaves, banked = {}, {}
  for sp, s in pairs(summary) do
    if (graph.leaves or {})[sp] then ownedLeaves[sp] = true end
    if (s.purePrincesses or 0) >= 1 then banked[sp] = true end
  end
  local plan = Traitmax.plan(graph, ownedLeaves, config.templates or {},
    Cfg.activeTraits(), Cfg.isGoodValue, banked)
  local target = Traitmax.nextDonor(graph, ownedLeaves, banked, plan.donorSet)
  return target, Traitmax.remaining(plan.donorSet, banked), plan
end

-- Whether a traitmax site is still in Phase A (acquiring donor species). True
-- only when traitmax-via-mutation is fully enabled (genebank + mutation graph +
-- templates all loaded) AND the site hasn't already finished acquiring. Once
-- runGenebankSchedule banks the last donor it sets site.traitmaxPhase="combine",
-- pinning the site into Phase B for the rest of the run. With any piece missing,
-- returns false -> the site is plain quality breeding (backward compatible).
function M.traitmaxAcquiring(config, site)
  if site.traitmaxPhase == "combine" then return false end
  return config.genebank ~= nil
    and config.mutationGraph ~= nil
    and config.templates ~= nil
end

-- One genebank-scheduled decision+action for a mutation OR rainbow site.
-- CARGO-FIRST + LAZY CENSUS: it trusts the cached storage census between visits
-- and reads live cargo for free, so the scheduler sees the accurate TOTAL without
-- a storage trip. It breeds straight from the resident working set when the job's
-- parents are already in cargo, and only flies to storage when a parent is missing
-- or cargo is too full to extract offspring (then it offloads surplus + refetches).
function M.runGenebankSchedule(config, site)
  -- Seed the storage census once; after that it's refreshed only on actual
  -- storage visits (below), which is the only time storage contents change.
  if not config._bankCensus then M.scanStorageCensus(config) end
  local cargoSummary, cargoConv, cargoKeys, cargoConvD = M.cargoCensus(config)
  local summary = M.mergeCensus(config._bankCensus, cargoSummary)
  local convertible = M.mergeConvertible(config._bankConvertible, cargoConv)
  local convertibleDrones = M.mergeConvertible(config._bankConvertibleDrones, cargoConvD)

  local target, remaining = site.targetSpecies, nil
  if site.mode == "rainbow" then
    target, remaining = rainbowTarget(config, summary)
    if not target then return "rainbow_complete" end
  elseif site.mode == "traitmax" then
    -- Phase A: acquire the donor species. When they're all banked, signal the
    -- dispatcher to flip the site into its combine phase (runQualitySite).
    local plan
    target, remaining, plan = traitmaxTarget(config, summary)
    if not target then
      site.traitmaxPhase = "combine"
      local unc = (plan and #plan.uncoverable > 0)
        and (" (uncoverable: " .. table.concat(plan.uncoverable, ", ") .. ")") or ""
      return "traitmax_donors_banked:combine" .. unc
    end
  end

  local state, plan = M.buildSchedulerState(config, site, summary, convertible, target, convertibleDrones)
  local job = Sched.nextJob(state)
  if job.type == "done" then
    -- Rainbow's target is always an UNBANKED species, so the scheduler only
    -- returns done for a single-target mutation site; rainbow re-picks next visit.
    if site.mode == "rainbow" then return "rainbow_banked:" .. target end
    if site.mode == "traitmax" then return "traitmax_donor_banked:" .. target end
    return "mutation_succeeded:switch_site_to_species_mode"
  end
  if job.type == "blocked" then
    local tag = (site.mode == "rainbow" and "rainbow") or (site.mode == "traitmax" and "traitmax") or nil
    return (tag and ("[" .. tag .. " " .. tostring(remaining) .. " left] ") or "")
      .. "blocked:" .. tostring(job.need)
  end

  -- Special-condition gate BEFORE fetching (don't move bees for a step we can't run).
  if job.type == "mutate" then
    local conditions = conditionsForResult(plan, job.result)
    if conditions and #conditions > 0 and not M.gateSpecialConditions(config, conditions, job.result) then
      return "awaiting_special_condition:" .. table.concat(conditions, "; ")
    end
  end

  -- Decide whether this attempt needs storage at all. If both parents are already
  -- resident and cargo has room to extract, breed with NO storage trip -- the
  -- whole point of the working set. Otherwise make ONE visit: offload surplus if
  -- we're choked, then re-scan (contents just changed) and refetch. The drone
  -- parent comes back as a full stack, so subsequent probabilistic retries stay
  -- resident.
  local resident = jobParentsResident(job, cargoKeys)
  local pressured = M.cargoFreeSlots(config) < (config.extractReserve or 3)
  local slotsByKey
  if resident and not pressured then
    slotsByKey = cargoKeys
  else
    if pressured then
      -- Protect THIS job's parents from being offloaded, so the next attempt of
      -- the same job (fix/seed loops repeat for many cycles) finds them resident
      -- and doesn't fly back to storage to re-fetch the identical carriers.
      local jspec = jobParentSpec(job)
      local protect = jspec and { [jspec.pKey] = true, [jspec.dKey] = true } or nil
      M.offloadSurplus(config, protect)
    end
    -- The census cache is kept current INCREMENTALLY by each deposit/fetch
    -- (M.censusApplyStack), so we no longer re-sweep every store on each visit --
    -- that full-store sweep was the "checks every single storage" cost. A periodic
    -- full rescan still runs as a self-healing safety net for any missed delta.
    config._censusTick = (config._censusTick or 0) + 1
    if (config._censusTick % (config.censusRescanEvery or 12)) == 0 then
      M.scanStorageCensus(config)
    end
    -- Void redundant hybrids of already-banked species (cargo + storage) before
    -- rebuilding slotsByKey, so a trashed slot is never handed to fetchJobParents.
    -- Piggybacks on this storage visit we're already making; re-scans if it culled.
    M.cullBankedHybrids(config)
    local _, _, freshCargoKeys = M.cargoCensus(config)
    slotsByKey = M.mergeSlotsByKey(config._bankSlotsByKey, freshCargoKeys)
  end

  local fetched, why = fetchJobParents(config, job, slotsByKey)
  if not fetched then return "fetch_failed:" .. job.type .. "(" .. tostring(why) .. ")" end
  if not gotoSite(site) then return "nav_failed_to_apiary" end
  return executeJobAtApiary(config, site, job)
end

-- Runs one decision+action cycle for a "mutation" site. Executes an
-- ordered breeding TREE toward site.targetSpecies: each visit plans (via
-- M.planMutationStep) and acts on the next actionable step, advancing
-- through intermediates automatically as they get bred and harvested.
function M.runMutationSite(config, site)
  Status.setStep("Heading to " .. (site.name or "?") .. " (mutation)")
  local ok, reason = gotoSite(site)
  if not ok then return "nav_failed:" .. tostring(reason) end

  local down = sides().down
  if beekeeper().canWork(down) then
    local progress = beekeeper().getBeeProgress(down)
    -- Same reasoning as runQualitySite's identical check: getBeeProgress
    -- completes the attempt on its final tick (consumes the queen) --
    -- if she's gone now, fall through into planning/loading the next
    -- attempt in this SAME visit instead of leaving the site idle for a
    -- whole extra cycle.
    if M.readSideSlot(down, 1) ~= nil then
      return string.format("attempting (%.0f%%)", progress)
    end

    -- Same reasoning as runQualitySite's identical step: harvest and
    -- analyze the just-created offspring/output immediately, before
    -- planning the next attempt below, so it's actually available as a
    -- candidate right away.
    M.harvestSite(config, site)
    M.analyzeWorkingSlots(config)
  end

  -- Clear any drone left stranded alone in slot 2 (see M.reclaimLoneDrone) so the
  -- site isn't left holding a lone drone with no princess between attempts.
  M.reclaimLoneDrone(config, site)

  -- Same last-known purity cache as runQualitySite (see the note there).
  -- A mutation site is often empty between attempts, in which case there
  -- is simply nothing to measure yet.
  local mutationTraits = M.traitListFor(site.mode)
  local sittingPrincess = M.readSideSlot(down, 1)
  if sittingPrincess then
    local sittingBee = toBreedingBee("princess", sittingPrincess, mutationTraits, site.targetSpecies)
    site.progress = M.purityOf(mutationTraits, sittingBee.genotype)
  end

  -- Guard BEFORE any dispatch (genebank scheduler -> executeJobAtApiary, or
  -- planMutationStep) -- both swapQueen+swapDrone unconditionally, so without
  -- this a canWork()==false read on a still-breeding queen would have her
  -- yanked out (swapQueen) and a new pair force-loaded mid-cycle. See
  -- M.apiaryLoadGuard.
  local guarded = M.apiaryLoadGuard(down, site)
  if guarded then return guarded end

  -- Once the FINAL target shows up in a harvest, hand off -- the site is
  -- expected to switch to "species" mode to purify it from here (see the
  -- header's mode notes). Checked before planning another attempt so a
  -- lucky success isn't immediately overwritten. Intermediates are NOT
  -- handed off here: they're just another owned species the plan below
  -- keeps building on toward the real target.
  -- Single-target mutation only: once the target shows up, hand off to species
  -- mode. (Rainbow has no single target -- it keeps building the next species.)
  if site.mode == "mutation" then
    for _, slot in ipairs(config.workingSlots) do
      local individual = M.readOwnSlot(slot)
      if individual and individual.active and Cfg.speciesKey(individual.active.species) == site.targetSpecies then
        return "mutation_succeeded:switch_site_to_species_mode"
      end
    end
  end

  -- Genebank / rainbow: hand straight off to the bank SCHEDULER
  -- (M.runGenebankSchedule) -- it builds each species' purebred bank bottom-up to
  -- full reserve, converts pristine hybrids to renew supply, and only spends a bank
  -- once it's stocked. Rainbow reuses the same machinery, just cycling the target
  -- through every reachable species.
  --
  -- NOTE: we deliberately DO NOT call M.junkHybrids here anymore. It predates the
  -- cargo-resident working set (v0.5.7/0.5.8) and actively breaks it: it flew to
  -- storage EVERY cycle to dump all hybrid DRONES -- but those are exactly the
  -- carrier fodder (census "W:" keys) the scheduler's `fix` job consumes to
  -- bootstrap the first pure of a mutated species. So it forced a guaranteed
  -- storage round-trip (dump, then `fix` re-fetches the same drones), starved the
  -- 2nd apiary of resident fix-parents, and -- writing to storage WITHOUT updating
  -- the lazy census cache -- left the scheduler's convertibleDrones count stale,
  -- causing mis-picked done/blocked/fetch-fail (harvest with no new pair loaded).
  -- Cargo bounding is now handled correctly by M.offloadSurplus inside the
  -- scheduler: pressure-gated, cache-refreshing, and it keeps the working set
  -- (incl. carriers) resident. Hybrids therefore stay in cargo as fix fodder.
  if config.genebank or site.mode == "rainbow" then
    return M.runGenebankSchedule(config, site)
  end

  local step, report = M.planMutationStep(config, site.targetSpecies, mutationTraits)
  if not step then
    return "waiting_on_parent_species:" .. (report or "no_known_recipe")
  end

  -- Special-condition gate: some steps need a foundation block / biome /
  -- dimension / climate / time the robot can't provide. Beep + await the
  -- user (or the injected confirmer) before committing the pair.
  if step.conditions and #step.conditions > 0 then
    if not M.gateSpecialConditions(config, step.conditions, step.subTarget) then
      return "awaiting_special_condition:" .. table.concat(step.conditions, "; ")
    end
  end

  local towardNote = (step.subTarget ~= site.targetSpecies)
    and (" toward " .. tostring(step.subTarget)) or ""
  Status.setStep(string.format("Attempting mutation at %s: %s x %s%s",
    site.name or "?", step.princessSpecies, step.droneSpecies, towardNote))
  agent().select(step.princessSlot)
  if not beekeeper().swapQueen(down) then return "swap_queen_failed" end
  local droneSlot = ensureSingleItemSlot(config, step.droneSlot)
  if not droneSlot then return "cargo_full_cannot_split_drone_stack" end
  agent().select(droneSlot)
  if not beekeeper().swapDrone(down) then return "swap_drone_failed" end

  return string.format("attempting mutation %s x %s%s (%.0f%% base chance)",
    step.princessSpecies, step.droneSpecies, towardNote, step.chance)
end

-- ============================================================
-- Harvesting: pull an apiary's product slots into working slots
-- ============================================================

-- Tracks which sites have already had a full slot dump logged (see the
-- harvested==0 diagnostic below) so a persistently-empty apiary doesn't
-- flood the log every cycle.
local diagDumpedSites = {}

-- Whether two raw item stacks would actually merge in a real inventory
-- slot: same item name, and if it's an analyzed bee, an EXACT genotype
-- match (Forestry only stacks genetically identical drones -- princesses/
-- queens never stack at all regardless of genotype, but those are
-- already excluded from anything routed through here -- see
-- isPrincessOrQueenStack). Species is a nested table ({name=,uid=,...}),
-- not directly comparable with == , so it's matched by contents instead.
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
  -- Also catch b having traits a lacks -- otherwise a strict subset match
  -- would slip through as "equal".
  for trait in pairs(bi.active or {}) do
    if ai.active == nil or ai.active[trait] == nil then return false end
  end
  return true
end

-- Picks the best destination slot for `incomingStack` among `slots`
-- (an array of slot numbers, not necessarily contiguous -- e.g.
-- config.workingSlots): an existing slot already holding a matching,
-- not-yet-full stack if one exists (so the real inventory slot mechanic
-- merges them instead of us wastefully spreading duplicates across
-- separate slots), otherwise the first empty slot. getStackFn(slot)
-- peeks that slot's raw stack (or nil if empty). Returns nil if neither
-- a mergeable nor an empty slot exists.
local function findStackingSlot(getStackFn, slots, incomingStack)
  local firstEmpty = nil
  for _, slot in ipairs(slots) do
    local existing = getStackFn(slot)
    if existing == nil then
      firstEmpty = firstEmpty or slot
    elseif stacksMatch(existing, incomingStack) and (existing.size or 1) < (existing.maxSize or 64) then
      return slot
    end
  end
  return firstEmpty
end

-- ============================================================
-- Multi-store helpers: the bee STORAGE network spans every config.storagePositions
-- block (see M.storagePositions). These visit each store in turn so scans and
-- deposits cover the whole network, not just one chest.
-- ============================================================

-- Visit every storage block and call fn(posIndex, slot, stack) for each non-empty
-- slot. Leaves the robot at the LAST store visited. Optional `label` is set as
-- the dashboard step at each store, so a sweep shows what it's DOING there (e.g.
-- "Scanning storage") instead of Nav's bare "Walking to (x,z)".
function M.forEachStorageStack(config, fn, label)
  local positions = M.storagePositions(config)
  local down = sides().down
  for pi, pos in ipairs(positions) do
    if Nav.gotoXZ(pos.x, pos.z) then
      if label then Status.setStep(string.format("%s (%d/%d)", label, pi, #positions)) end
      local size = invCtrl().getInventorySize(down) or config.storageSlotCount or 54
      for s = 1, size do
        local stack = invCtrl().getStackInSlot(down, s)
        if stack then fn(pi, s, stack) end
      end
    end
  end
end

-- Deposit the cargo bees named by `entries` ({ { _slot = cargoSlot }, ... }) into
-- the storage network, filling one store before spilling into the next (genome-
-- aware stacking, then first empty). Returns dropped, pending -- pending are the
-- entries that had NOWHERE to go (every store full). Leaves the robot at the last
-- store it needed.
function M.depositBeesAcrossStores(config, entries)
  local positions = M.storagePositions(config)
  local down = sides().down
  local dropped, pending = 0, entries
  for pi, pos in ipairs(positions) do
    if #pending == 0 then break end
    if Nav.gotoXZ(pos.x, pos.z) then
      local size = invCtrl().getInventorySize(down) or config.storageSlotCount or 54
      local candidateSlots = {}
      for s = 1, size do candidateSlots[s] = s end
      local rest = {}
      for _, e in ipairs(pending) do
        local incoming = invCtrl().getStackInInternalSlot(e._slot)
        local slot = incoming and findStackingSlot(
          function(s) return invCtrl().getStackInSlot(down, s) end, candidateSlots, incoming)
        if slot then
          local moved = incoming.size or 1
          agent().select(e._slot)
          if invCtrl().dropIntoSlot(down, slot) then
            dropped = dropped + 1
            M.censusApplyStack(config, pi, slot, incoming, moved, false) -- keep cache current
          else
            rest[#rest + 1] = e
          end
        else
          rest[#rest + 1] = e
        end
      end
      pending = rest
    end
  end
  return dropped, pending
end

-- Forestry apiaries expose product/offspring output (combs, drones, the
-- replacement princess) in every slot beyond the queen(1)/drone(2) pair.
-- Confirmed via probeInventoryBelow() against real hardware: the old
-- 7-15 range (inherited from beeManager.lua's Transposer-based version)
-- was flat-out wrong for this apiary -- product was actually sitting in
-- slots 3-6, with 7+ empty. Rather than hardcode another guessed range
-- that might not hold for a different apiary tier/type, this derives
-- "every slot from 3 to the apiary's real reported size" unless
-- config.productSlots explicitly overrides it.
function M.harvestSite(config, site, productSlots)
  productSlots = productSlots or config.productSlots
  Status.setStep("Harvesting " .. (site.name or "?"))
  local ok = gotoSite(site)
  if not ok then return 0 end

  local down = sides().down
  -- A Robot's inventory_controller.suckFromSlot validates the slot against
  -- the TARGET inventory's real size and throws "invalid slot" for
  -- anything beyond it -- unlike a Transposer, which just silently
  -- returns nil for an out-of-range slot. Different apiary tiers/types
  -- have different inventory sizes, so this asks the real hardware
  -- instead of assuming.
  local size = invCtrl().getInventorySize(down)

  if not productSlots then
    productSlots = {}
    for slot = 3, (size or 15) do table.insert(productSlots, slot) end
  end

  local harvested = 0
  -- Trace birth-detection: Minecraft (not our sim) does the actual mating, so
  -- the offspring genomes -- the inheritance RNG the sim needs to import -- can
  -- only be observed as the bees that come OUT of the apiary. Collect the raw
  -- bee stacks harvested this call and hand them to M.traceOnHarvest (set only
  -- by the trace runner); it's a no-op on a normal run.
  local birthStacks = M.traceOnHarvest and {} or nil
  for _, productSlot in ipairs(productSlots) do
    if not size or productSlot <= size then
      -- Peeking first isn't just diagnostic -- it avoids burning a
      -- suckFromSlot call (and a working-slot pick) on a slot we can
      -- already see is empty.
      local peek = invCtrl().getStackInSlot(down, productSlot)
      if peek then
        if birthStacks and peek.individual then birthStacks[#birthStacks + 1] = peek end
        -- Prefers merging into an existing matching, not-yet-full cargo
        -- stack over always taking a fresh empty slot -- without this,
        -- identical harvested drones/combs spread across separate slots
        -- one at a time instead of stacking together.
        local workingSlot = findStackingSlot(invCtrl().getStackInInternalSlot, config.workingSlots, peek)
        if workingSlot then
          -- suckFromSlot lands in the CURRENTLY SELECTED slot, same as
          -- swapQueen/swapDrone/dropIntoSlot elsewhere in this file --
          -- it does not auto-pick an empty slot on its own. Pulls the
          -- WHOLE stack in one go (peek.size), not a hardcoded 1 -- a
          -- product slot holding several genetically identical drones
          -- (they stack, same as cargo) otherwise only ever gave up one
          -- unit per visit, leaving the rest sitting there indefinitely
          -- since a fresh visit re-peeks and re-splits the same way
          -- every time. Real hardware/suckFromSlot itself still caps
          -- this at whatever the destination has room for, same as any
          -- other transfer.
          agent().select(workingSlot)
          local moved = invCtrl().suckFromSlot(down, productSlot, peek.size)
          if moved and moved > 0 then harvested = harvested + moved end
        end
      end
    end
  end

  -- One-time-per-site full slot dump if harvesting ever comes up empty
  -- despite the apiary genuinely having a real size -- catches a future
  -- "productSlots doesn't match this apiary" regression the same way
  -- probeInventoryBelow() caught it manually before this existed, without
  -- needing a manual probe step or flooding the log on every normal
  -- "nothing ready yet" cycle.
  if harvested == 0 and size and not diagDumpedSites[site.name] then
    diagDumpedSites[site.name] = true
    local dump = { string.format("[harvest-diag-full] %s: dumping all %d slots:", site.name or "?", size) }
    for slot = 1, size do
      local stack = invCtrl().getStackInSlot(down, slot)
      if stack then
        table.insert(dump, string.format("  slot %d: %s x%s (%s)",
          slot, tostring(stack.name), tostring(stack.size), tostring(stack.label)))
      end
    end
    if #dump == 1 then table.insert(dump, "  (every slot reported empty)") end
    print(table.concat(dump, "\n"))
  end
  if birthStacks and #birthStacks > 0 then
    M.traceOnHarvest((site.x or 0) .. ":" .. (site.z or 0), birthStacks)
  end
  return harvested
end

-- ============================================================
-- Storage/trash: fly discarded drones to a position and drop them into the
-- first empty slot found there. Shared by M.dumpToStorage (a plain chest,
-- kept for later) and M.dumpToTrash (e.g. Extra Utilities' Trash Can,
-- permanently voided) -- same mechanic, different destination. Default
-- discard destination when config.onDiscard isn't set (see
-- M.runQualitySite's discard block for the trash-preferred-over-storage
-- ordering).
-- ============================================================

local function dumpEntriesAt(pos, slotCount, discardEntries, keepId)
  if not pos then return 0 end
  local ok = Nav.gotoXZ(pos.x, pos.z)
  if not ok then return 0 end

  local down = sides().down
  -- Prefers the REAL reported size over the configured fallback -- same
  -- reasoning as M.restockFromStorage/M.analyzeWorkingSlots' honey
  -- restock already use: a hardcoded slot count silently wastes room in
  -- a larger real container, or tries to address slots that don't
  -- exist at all in a smaller one. This was the one place in the file
  -- that never queried dynamically, only ever trusting the config
  -- value (or a bare 54 guess).
  slotCount = invCtrl().getInventorySize(down) or slotCount or 54
  local candidateSlots = {}
  for s = 1, slotCount do table.insert(candidateSlots, s) end

  local dropped = 0
  for _, entry in ipairs(discardEntries) do
    if entry.drone.id ~= keepId and entry.drone._slot then
      local incoming = invCtrl().getStackInInternalSlot(entry.drone._slot)
      -- Prefers merging into an existing matching, not-yet-full stack
      -- already sitting in storage/trash over always taking a fresh
      -- empty slot -- without this, identical discarded drones pile up
      -- across separate slots one at a time instead of stacking.
      local slot = findStackingSlot(function(s) return invCtrl().getStackInSlot(down, s) end, candidateSlots, incoming)
      if slot then
        agent().select(entry.drone._slot)
        if invCtrl().dropIntoSlot(down, slot) then
          dropped = dropped + 1
        end
      end
    end
  end
  return dropped
end

-- The list of bee-storage positions, in fill order. Storage is TYPE-AGNOSTIC:
-- each position is any inventory block (plain chest, barrel, Storage Drawer,
-- Apiarist's Chest) addressed by {x,z}/side=down, its real size queried per
-- block. Prefers the multi-store config.storagePositions; falls back to the
-- single legacy config.storagePos so nothing that only set the old field breaks.
function M.storagePositions(config)
  if config.storagePositions and #config.storagePositions > 0 then
    return config.storagePositions
  end
  if config.storagePos then return { config.storagePos } end
  return {}
end

-- STORAGE FULL handler: every storage block is full and `pending` bees have
-- nowhere to go. Per the user's design the robot STOPS and BEEPS rather than
-- silently dropping bees on the floor. config.onStorageFull(config, pending)
-- overrides (tests inject one that records the event instead of blocking). The
-- real-hardware default beeps and blocks until the user frees a store and pokes
-- the robot (any signal) -- same beep+pullSignal pattern as the special-condition
-- gate. Returns nothing; the caller has already placed everything it could.
function M.onStorageFull(config, pending)
  if config.onStorageFull then return config.onStorageFull(config, pending) end
  Status.setStep("STORAGE FULL -- halted (free a store, then poke the robot)")
  print(string.format("[storage full] All %d storage block(s) are full; %d bee(s) have nowhere to go.",
    #M.storagePositions(config), pending and #pending or 0))
  print("   Empty or add a store, then press any key / poke the robot to continue...")
  local computer = require("computer")
  while true do
    M.beepAlert()
    local ok, ev = pcall(function() return computer.pullSignal(5) end)
    if not ok then break end        -- host without pullSignal: don't spin forever
    if ev ~= nil then break end      -- a real signal arrived -> user intervened
  end
end

-- Fly discarded bees to storage, spreading across every storage block in fill
-- order: fill store 1, spill the rest into store 2, and so on. If bees still
-- remain after the LAST store, storage is genuinely full -> M.onStorageFull
-- (stop + beep). Returns the number actually deposited.
function M.dumpToStorage(config, discardEntries, keepId)
  if #M.storagePositions(config) == 0 then return 0 end
  Status.setStep("Flying discards to storage")

  -- The bees actually eligible to move (skip the keepId and slot-less entries),
  -- mapped to the { _slot } shape depositBeesAcrossStores wants.
  local entries = {}
  for _, e in ipairs(discardEntries) do
    if e.drone.id ~= keepId and e.drone._slot then entries[#entries + 1] = { _slot = e.drone._slot } end
  end

  local dropped, pending = M.depositBeesAcrossStores(config, entries)
  if #pending > 0 then M.onStorageFull(config, pending) end
  return dropped
end

function M.dumpToTrash(config, discardEntries, keepId)
  Status.setStep("Flying discards to trash")
  return dumpEntriesAt(config.trashPos, config.trashSlotCount or 1, discardEntries, keepId)
end

-- Is `species` already banked to its maintenance reserve? Reads the census
-- cached by M.syncBanksToStorage. A missing cache, a species not in it, or no
-- genebank config all mean "not banked" -> its bees are preserved, never voided.
-- This is the gate behind the bank-gated discard policy: base-species genetics
-- are the scarce resource, so nothing gets trashed until its species has a real
-- bank (>= minDrones purebred drones) that makes further copies genuinely
-- redundant.
function M.isSpeciesBanked(config, species)
  local census = config._bankCensus
  if not census then return false end
  local rec = census[species]
  if not rec then return false end
  local minD = (config.genebank and config.genebank.minDrones) or 8
  return rec.pureDrones >= minD
end

-- Does `species` have a SELF-SUSTAINING pure set -- at least one pure princess
-- AND one pure drone -- so more pure copies of it can always be bred? This is a
-- stronger, safer gate than isSpeciesBanked for deciding a hybrid is discardable:
-- a hybrid carries TWO species, and it may be the only carrier of the genes of
-- EITHER of them, so it's only truly redundant once BOTH its species can stand
-- on their own. Reads the census cache; no genebank config / not scanned -> false.
function M.speciesHasPureSet(config, species)
  local census = config._bankCensus
  if not census then return false end
  local rec = census[species]
  if not rec then return false end
  return (rec.purePrincesses or 0) >= 1 and (rec.pureDrones or 0) >= 1
end

-- PURE, unit-tested. Splits discard entries into (trashable, preserve). A drone
-- is trash-eligible only when EVERY species allele it carries is already banked
-- -- until then it may be the only seed for that species' bank, so it's
-- preserved. Entries whose species can't be determined (unanalyzed) are always
-- preserved. allelesOf(entry) -> { [species]=true, ... } or nil; isBanked(sp) -> bool.
function M.partitionDiscards(entries, allelesOf, isBanked)
  local trashable, preserve = {}, {}
  for _, e in ipairs(entries) do
    local alleles = allelesOf(e)
    local eligible = alleles ~= nil
    if eligible then
      for sp in pairs(alleles) do
        if not isBanked(sp) then eligible = false; break end
      end
    end
    if eligible then trashable[#trashable + 1] = e else preserve[#preserve + 1] = e end
  end
  return trashable, preserve
end

-- Bank-gated discard router -- the single place off-target drones get shed.
-- Replaces the old "trash if trashPos else storage" blocks: it PRESERVES (routes
-- to the storage network, keeping the genes) every bee whose species isn't yet
-- banked, and only VOIDS (trash) the genuinely-redundant byproducts of species
-- that already have a full bank. Falls back gracefully when only one destination
-- exists. Returns the number of bees actually deposited.
function M.dumpDiscards(config, discardEntries, keepId)
  local function allelesOf(e)
    if not (e.drone and e.drone._slot) then return nil end
    local c = classifyBee(invCtrl().getStackInInternalSlot(e.drone._slot))
    return c and c.alleles or nil
  end
  local function isBanked(sp) return M.isSpeciesBanked(config, sp) end
  local trashable, preserve = M.partitionDiscards(discardEntries, allelesOf, isBanked)

  local haveStorage = #M.storagePositions(config) > 0
  local dropped = 0
  -- Preserve group: storage first (genes kept); trash only as a last resort when
  -- there's no storage at all, to avoid choking cargo.
  if #preserve > 0 then
    if haveStorage then dropped = dropped + M.dumpToStorage(config, preserve, keepId)
    elseif config.trashPos then dropped = dropped + M.dumpToTrash(config, preserve, keepId) end
  end
  -- Trashable group (already-banked, redundant): void it; fall back to storage
  -- if no trash can is configured.
  if #trashable > 0 then
    if config.trashPos then dropped = dropped + M.dumpToTrash(config, trashable, keepId)
    elseif haveStorage then dropped = dropped + M.dumpToStorage(config, trashable, keepId) end
  end
  return dropped
end

-- Anti-hoarding sweep: void genuinely-redundant hybrids of species that ALREADY
-- have a full purebred bank. Once M.isSpeciesBanked(species) holds, that species'
-- hybrid DRONES only drift the bank and its IGNOBLE (bred, degrading;
-- isNatural == false) hybrid princesses are dead weight -- both are trashed.
-- NEVER touched: purebred bees (the banks), PRISTINE hybrid princesses
-- (isNatural ~= false -- renewable stock AND fix-fodder for species not yet
-- banked), and every bee of a not-yet-banked species (still that species' only
-- seed). This is what the old (unwired) M.junkHybrids failed to do safely: it
-- dumped ALL hybrid drones every cycle, trashing the fix-fodder needed to
-- bootstrap a species' first purebred. Sweeps cargo AND the whole storage
-- network, extracting storage targets into free cargo slots as it visits each
-- store, then voids everything in ONE trash trip. Re-scans the census if it
-- removed anything (the removed hybrids were counted in convertible/*). Returns
-- the number voided. No-op without a trash location, or before anything is
-- banked (nothing is redundant yet).
function M.cullBankedHybrids(config)
  if not config.trashPos then return 0 end -- nowhere to void -> keep everything
  -- THROTTLE: this does a storage sweep + trash trip, so don't run it every
  -- pressured cycle (that would pile onto the storage traffic we're trying to
  -- keep low). The hoard grows slowly; culling every Nth storage visit drains it
  -- without adding a sweep to most visits. config.cullEveryVisits overrides.
  config._cullVisits = (config._cullVisits or 0) + 1
  if (config._cullVisits % (config.cullEveryVisits or 8)) ~= 0 then return 0 end
  if not config._bankCensus then M.scanStorageCensus(config) end

  local anyPureSet = false
  for sp in pairs(config._bankCensus or {}) do
    if M.speciesHasPureSet(config, sp) then anyPureSet = true; break end
  end
  if not anyPureSet then return 0 end -- early game: nothing has a pure set yet
  Status.setStep("Culling redundant hybrids of banked species")

  local function cullEligible(stack)
    local c = classifyBee(stack)
    if not c or c.pure then return false end -- non-bee / purebred -> keep
    -- A hybrid carries TWO species (active + inactive) -- it may be the only
    -- carrier of EITHER. Discard it only once BOTH already have a self-sustaining
    -- pure set (pure princess AND drone), else keep it as that species' seed.
    for sp in pairs(c.alleles) do
      if not M.speciesHasPureSet(config, sp) then return false end
    end
    if c.role == "drone" then return true end -- redundant hybrid drone
    local ind = readIndividual(stack) -- hybrid princess: trash only IGNOBLE (bred) ones
    return (ind and ind.isNatural == false) or false
  end

  local function firstFreeCargo()
    for _, cs in ipairs(config.workingSlots) do
      if cs ~= config.honeySlot and invCtrl().getStackInInternalSlot(cs) == nil then return cs end
    end
    return nil
  end

  -- Cargo targets first (identifiable without any travel).
  local entries = {}
  for _, cslot in ipairs(config.workingSlots) do
    if cslot ~= config.honeySlot then
      local stack = invCtrl().getStackInInternalSlot(cslot)
      if stack and cullEligible(stack) then
        entries[#entries + 1] = { drone = { id = "cull:c" .. cslot, _slot = cslot } }
      end
    end
  end

  -- Storage targets: extract into free cargo slots while standing at each store,
  -- so the single trash trip below voids them together with the cargo ones. Stops
  -- adding once cargo is full (no free slot) -- the rest get swept a later visit.
  local down = sides().down
  M.forEachStorageStack(config, function(_pos, slot, stack)
    if cullEligible(stack) then
      local dest = firstFreeCargo()
      if dest then
        agent().select(dest)
        if (invCtrl().suckFromSlot(down, slot, stack.size or 1) or 0) > 0 then
          entries[#entries + 1] = { drone = { id = "cull:s" .. slot, _slot = dest } }
        end
      end
    end
  end, "Culling redundant hybrids")

  if #entries == 0 then return 0 end
  local voided = M.dumpToTrash(config, entries)
  if voided > 0 then M.scanStorageCensus(config) end -- census counted these; refresh it
  return voided
end

-- ============================================================
-- Restocking: pull analyzed bees back OUT of storage into free working
-- slots. Without this, once a drone is flown to storage it's gone from
-- the breeding pool forever from the algorithm's point of view, even
-- though it's still physically sitting right there -- storage becomes a
-- one-way trip instead of a real fallback pool. Called from M.runCycle
-- when a site's decision came up empty-handed (no usable candidates in
-- cargo at all).
-- ============================================================

function M.restockFromStorage(config)
  local positions = M.storagePositions(config)
  if #positions == 0 then return 0 end

  -- Cheap upfront check -- not worth a whole trip if cargo has zero
  -- room to receive anything at all. (Once there, actual destination
  -- selection also considers merging into an existing matching stack,
  -- not just this empty-slot count -- see findStackingSlot below.)
  local hasFreeSlot = false
  for _, slot in ipairs(config.workingSlots) do
    if invCtrl().getStackInInternalSlot(slot) == nil then
      hasFreeSlot = true
      break
    end
  end
  if not hasFreeSlot then return 0 end

  Status.setStep("Restocking from storage")
  local down = sides().down
  local restocked = 0
  -- Visit each apiarist chest until cargo has no more room to receive.
  for _, pos in ipairs(positions) do
    if not Nav.gotoXZ(pos.x, pos.z) then
      -- skip an unreachable chest, try the next
    else
      local size = invCtrl().getInventorySize(down) or config.storageSlotCount or 54
      for slot = 1, size do
        local stack = invCtrl().getStackInSlot(down, slot)
        if stack and readIndividual(stack) then
          -- Prefers merging into an existing matching, not-yet-full cargo
          -- stack over always claiming a fresh empty slot -- without this,
          -- a restocked bee never stacked together with an identical one
          -- already sitting in cargo, one at a time forever.
          local destSlot = findStackingSlot(invCtrl().getStackInInternalSlot, config.workingSlots, stack)
          if destSlot then
            agent().select(destSlot)
            -- Pulls the WHOLE matching stack in one go, not a hardcoded 1
            -- -- otherwise several identical bees stacked in one storage
            -- slot only ever gave up one unit per visit.
            local moved = invCtrl().suckFromSlot(down, slot, stack.size or 1)
            if moved and moved > 0 then restocked = restocked + 1 end
          end
        end
      end
    end
  end
  return restocked
end

-- ============================================================
-- Analysis: find unanalyzed bees in working slots and analyze them
-- ============================================================

-- Finds honey/honeydew wherever it actually is in the agent's own
-- inventory, rather than assuming it's permanently sitting in
-- config.honeySlot. Searches the WHOLE inventory (not just
-- workingSlots, which deliberately excludes honeySlot by convention).
-- Returns nil if nothing matches -- NO config.honeySlot fallback here
-- (see M.analyzeWorkingSlots, which tries restocking from storage first
-- and only falls back to the configured slot as an absolute last
-- resort).
-- Matches on EITHER the registered item name (stack.name, e.g.
-- "forestry:honey_drop") OR the display label (stack.label, e.g. "Honey
-- Drop") -- checking name alone risks a silent miss if this pack's
-- actual Forestry build registers honey/honeydew under an ID that
-- doesn't literally contain either substring even though its label
-- obviously does (or vice versa). Widening the match can only catch
-- MORE real honey, never cause a false positive on an unrelated item
-- (nothing else is remotely likely to have "honey"/"honeydew" in either
-- its id or its display name).
local function looksLikeHoney(stack)
  if not stack then return false end
  local name = stack.name and stack.name:lower() or ""
  local label = stack.label and stack.label:lower() or ""
  -- Bee Combs are a totally different, real Forestry item (a crafting/
  -- processing byproduct, e.g. Forestry:beeCombs, harvested from an
  -- apiary the same as anything else) -- never usable for
  -- beekeeper.analyze(). But several comb variants are literally
  -- LABELED "Honey Comb", which would otherwise false-positive match on
  -- "honey" alone. Confirmed as the real bug: Honey Comb sitting in
  -- config.honeySlot was treated as valid honey, so restockHoney never
  -- detected the slot as "occupied by something else" and kept trying
  -- to suck real Honeydew on top of it -- which silently fails (two
  -- genuinely different items can't merge into the same slot), leaving
  -- analyze() starved of real honey the entire time.
  if name:find("comb") or label:find("comb") then return false end
  return name:find("honey") or name:find("honeydew") or label:find("honey") or label:find("honeydew")
end

local function searchForHoney()
  local size = robotLib().inventorySize() or 16
  for slot = 1, size do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if looksLikeHoney(stack) then return slot end
  end
  return nil
end

-- Sums EVERY honey/honeydew stack currently in cargo (not just the
-- first one found -- see searchForHoney), across the robot's FULL
-- inventory. Used to seed/true-up config.honeyCount, the running
-- estimate M.runCycle checks proactively each cycle (see its header
-- notes) instead of only reacting after a site's own analysis attempt
-- already discovers cargo is empty.
local function countHoneyInCargo()
  local size = robotLib().inventorySize() or 16
  local total = 0
  for slot = 1, size do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if looksLikeHoney(stack) then total = total + (stack.size or 1) end
  end
  return total
end
M.countHoneyInCargo = countHoneyInCargo

-- Tracks whether the "nothing matched honey/honeydew by name" full dump
-- (see M.restockHoney below) has already fired once, so a persistently
-- empty/mismatched storage doesn't flood the log every cycle.
local diagRestockDumped = false

-- Tracks which early-return REASONS restockHoney has already logged
-- once (keyed by reason string), so a persistent condition (e.g.
-- config.honeySlot never set) doesn't flood the log every cycle, but a
-- DIFFERENT reason on a later call still gets its own one-time print.
-- Every prior restockHoney fix addressed one specific failure mode
-- (destination selection, label matching, ...) but most of its early
-- returns were completely silent -- no way to tell WHICH one is
-- actually happening this time without seeing it logged directly.
local diagRestockReasonsLogged = {}
local function logRestockFailure(reason)
  if not diagRestockReasonsLogged[reason] then
    diagRestockReasonsLogged[reason] = true
    print("[restock-diag] restockHoney gave up: " .. reason)
  end
end

-- Flies to a honey source (config.honeyStoragePos, a dedicated location
-- if you keep honey separate from general storage, falling back to
-- config.storagePos) and pulls a full stack back into config.honeySlot
-- specifically (see below for why). Without this, once cargo's honey
-- genuinely runs dry there was no way to recover even with a full stack
-- sitting in a chest -- analysis
-- would just silently stop working forever.
function M.restockHoney(config)
  local honeyPos = config.honeyStoragePos or config.storagePos
  if not honeyPos then
    logRestockFailure("no config.honeyStoragePos or config.storagePos known")
    return false
  end

  -- ALWAYS targets config.honeySlot specifically, never some other
  -- working slot. Confirmed on real hardware: beekeeper.analyze() only
  -- ever actually consumes honey physically sitting in config.honeySlot
  -- -- regardless of what slot number gets passed as its argument, it
  -- ignores honey sitting anywhere else. Landing restocked honey in a
  -- different (merely empty, or partially-stocked) working slot would
  -- just be inert cargo clutter analyze() can never actually use.
  if not config.honeySlot then
    logRestockFailure("config.honeySlot is not set at all")
    return false
  end
  local existing = invCtrl().getStackInInternalSlot(config.honeySlot)
  if existing and not looksLikeHoney(existing) then
    -- Something else is occupying the honey slot -- not ours to use.
    logRestockFailure(string.format(
      "config.honeySlot (%d) is occupied by something that isn't honey: name=%s label=%s",
      config.honeySlot, tostring(existing.name), tostring(existing.label)))
    return false
  end
  if existing and (existing.size or 1) >= (existing.maxSize or 64) then
    logRestockFailure(string.format("config.honeySlot (%d) is already full (%s/%s)",
      config.honeySlot, tostring(existing.size), tostring(existing.maxSize)))
    return false -- already full, nothing to restock
  end
  local freeSlot = config.honeySlot

  Status.setStep("Fetching honey from storage")
  local ok, navReason = Nav.gotoXZ(honeyPos.x, honeyPos.z)
  if not ok then
    logRestockFailure(string.format("failed to navigate to honey position (%s,%s): %s",
      tostring(honeyPos.x), tostring(honeyPos.z), tostring(navReason)))
    return false
  end

  local down = sides().down
  local size = invCtrl().getInventorySize(down) or config.storageSlotCount or 54
  for slot = 1, size do
    local stack = invCtrl().getStackInSlot(down, slot)
    if looksLikeHoney(stack) then
      agent().select(freeSlot)
      local moved = invCtrl().suckFromSlot(down, slot, 64)
      if moved and moved > 0 then return true end
      -- Matched by name/label, but suckFromSlot moved nothing -- fires
      -- immediately, not gated by diagRestockDumped, since this is a
      -- much more specific/unusual failure worth seeing right away
      -- (e.g. the destination slot rejected it, or the source
      -- reported a stack that wasn't actually still there).
      print(string.format(
        "[restock-diag] matched slot %d (name=%s label=%s x%s) but suckFromSlot(side=%s, slot=%d, count=64) into freeSlot=%d moved %s",
        slot, tostring(stack.name), tostring(stack.label), tostring(stack.size), tostring(down), slot, freeSlot, tostring(moved)))
    end
  end

  -- One-time full dump if NOTHING in the whole inventory ever matched
  -- "honey"/"honeydew" by name -- same reasoning as M.harvestSite's own
  -- "harvest-diag-full" dump: catches a real-hardware naming mismatch
  -- (this pack's actual item name/label not containing either substring)
  -- directly in the log, instead of restockHoney just silently
  -- returning false forever with zero forensic information.
  if not diagRestockDumped then
    diagRestockDumped = true
    local dump = { string.format("[restock-diag-full] %s: dumping all %d slots, nothing matched honey/honeydew by name:",
      tostring(honeyPos and (honeyPos.x .. "," .. honeyPos.z)), size) }
    for slot = 1, size do
      local stack = invCtrl().getStackInSlot(down, slot)
      if stack then
        table.insert(dump, string.format("  slot %d: name=%s label=%s x%s",
          slot, tostring(stack.name), tostring(stack.label), tostring(stack.size)))
      end
    end
    if #dump == 1 then table.insert(dump, "  (every slot reported empty)") end
    print(table.concat(dump, "\n"))
  end

  return false
end

function M.analyzeWorkingSlots(config)
  local analyzed = 0
  local honeySlot = searchForHoney()
  if not honeySlot then
    -- Cargo genuinely has none -- try fetching more before giving up.
    if M.restockHoney(config) then
      config.honeyCount = countHoneyInCargo()
      honeySlot = searchForHoney()
    end
  end
  -- Absolute last resort: real hardware might report a different item
  -- name than expected -- better to try the configured slot than
  -- analyze nothing at all.
  honeySlot = honeySlot or config.honeySlot
  if not honeySlot then return 0 end

  -- analyze() only ever actually consumes honey physically sitting in
  -- config.honeySlot on real hardware -- confirmed: it only worked when
  -- honey was in slot 1, regardless of what slot number got passed as
  -- its argument. If searchForHoney found it somewhere ELSE (e.g.
  -- honeydew harvested organically into a random working slot, or a
  -- leftover stack from before this fix), physically consolidate it
  -- into config.honeySlot first -- omitting the count moves the WHOLE
  -- stack (real robot.transferTo default), merging with whatever's
  -- already there.
  if config.honeySlot and honeySlot ~= config.honeySlot then
    agent().select(honeySlot)
    if agent().transferTo(config.honeySlot) then
      honeySlot = config.honeySlot
    end
  end

  for _, slot in ipairs(config.workingSlots) do
    local stack = invCtrl().getStackInInternalSlot(slot)
    if stack and stack.individual and not stack.individual.isAnalyzed then
      -- Honey ran out partway through THIS SAME batch (several
      -- unanalyzed bees in one visit, more than one stack's worth of
      -- honey) -- restock immediately, high priority, rather than
      -- leaving the rest of this visit's bees unanalyzed until some
      -- unrelated later cycle happens to trigger a restock. Verifies
      -- with a real scan first (same reasoning as M.runCycle's
      -- proactive check) -- the tracked estimate can drift, so don't
      -- commit to a whole trip until confirming cargo is actually low.
      if config.honeyCount and config.honeyCount <= 0 then
        config.honeyCount = countHoneyInCargo()
        if config.honeyCount <= 0 and M.restockHoney(config) then
          config.honeyCount = countHoneyInCargo()
          honeySlot = searchForHoney() or honeySlot
        end
      end
      Status.setStep("Analyzing bee in slot " .. slot)
      agent().select(slot)
      local ok = beekeeper().analyze(honeySlot)
      if ok then
        analyzed = analyzed + 1
        if config.honeyCount then config.honeyCount = math.max(0, config.honeyCount - 1) end
      end
    end
  end
  return analyzed
end

-- Sweeps ALL of cargo for stacks that could merge together but haven't
-- -- e.g. two already-analyzed stacks with identical alleles that came
-- from different originating batches. Forestry bee items with
-- different isAnalyzed states never stack even with identical alleles,
-- so a freshly-harvested unanalyzed bee correctly couldn't merge with
-- an already-analyzed matching stack when it first arrived -- but real
-- Minecraft doesn't auto-re-stack two existing separate slots just
-- because their NBT now happens to agree once it's analyzed too, and
-- neither does merely reacting to THAT one transition: two stacks that
-- were EACH ALREADY analyzed from separate origins never get a "just
-- changed state" moment to trigger against each other at all. This is
-- a general, unconditional sweep instead -- purely cargo bookkeeping,
-- no travel needed. Confirmed as the real bug: the same exact genotype
-- ended up scattered across many separate cargo slots instead of one
-- consolidated stack, and only reacting to the analyze-transition still
-- left several of them un-merged with each other.
function M.consolidateCargo(config)
  local merged = 0
  for i, slotA in ipairs(config.workingSlots) do
    local a = invCtrl().getStackInInternalSlot(slotA)
    if a and (a.size or 1) < (a.maxSize or 64) then
      for j = i + 1, #config.workingSlots do
        local slotB = config.workingSlots[j]
        local b = invCtrl().getStackInInternalSlot(slotB)
        if b and stacksMatch(a, b) then
          agent().select(slotB)
          if agent().transferTo(slotA) then
            merged = merged + 1
            a = invCtrl().getStackInInternalSlot(slotA) -- refresh: size just grew
            if not a or (a.size or 1) >= (a.maxSize or 64) then break end
          end
        end
      end
    end
  end
  return merged
end

-- ============================================================
-- Working slots: if config.workingSlots isn't explicitly set, use every
-- slot from 1 to the robot's REAL inventory size except honeySlot,
-- instead of a fixed hardcoded list. A fixed list (e.g. hardcoded to 16)
-- silently wastes any additional Inventory Upgrade slots the robot
-- actually has installed -- call this once at startup (see
-- bee_keeper_manager_run.lua) and assign the result back into
-- config.workingSlots.
-- ============================================================

function M.resolveWorkingSlots(config)
  if config.workingSlots then return config.workingSlots end
  local size = robotLib().inventorySize() or 16
  local slots = {}
  for slot = 1, size do
    if slot ~= config.honeySlot then table.insert(slots, slot) end
  end
  return slots
end

-- ============================================================
-- Site loading: merges bee_keeper_setup.lua's persisted (x,z) discoveries
-- with the mode/targetSpecies assignments you configure by hand, keyed by
-- site name (site1, site2, ... as assigned during the scan). Anything not
-- explicitly overridden defaults to "traitmax".
-- ============================================================

function M.loadSites(savedSites, siteOverrides)
  siteOverrides = siteOverrides or {}
  local sites = {}
  for _, s in ipairs(savedSites) do
    local override = siteOverrides[s.name] or {}
    table.insert(sites, {
      name = s.name,
      x = s.x,
      z = s.z,
      mode = override.mode or "traitmax",
      targetSpecies = override.targetSpecies,
    })
  end
  return sites
end

-- ============================================================
-- Mutation graph loading: reads the committed bee_mutations.dat (the
-- one-time GTNH dump -- see scripts/dump_bee_data.lua / docs/oc_forestry_api.md)
-- and builds it into the indexed graph the tree planner consumes, storing
-- it on config.mutationGraph. Only needed if any site runs in "mutation"
-- mode; a missing/unreadable file is non-fatal (mutation sites then just
-- report "no_mutation_graph_loaded" instead of crashing). Called once at
-- startup from bee_keeper_manager_run.lua.
-- ============================================================

function M.loadMutationGraph(config, path)
  path = path or "bee_mutations.dat"
  local f = io.open(path, "r")
  if not f then return nil, "not_found:" .. path end
  local serialized = f:read("*a")
  f:close()
  if not serialized or serialized == "" then return nil, "empty:" .. path end
  local ok, graph = pcall(MG.parse, serialized)
  if not ok or not graph then return nil, "parse_failed:" .. tostring(graph) end
  config.mutationGraph = graph
  return graph
end

-- Species DEFAULT allele templates for traitmax-via-mutation: parsed from the
-- mod sources into bee_templates.dat (see docs/data_sources.md), loaded into
-- config.templates (Java-enum-keyed raw form; bee_traitmax.plan reconciles to
-- live names). Only needed by traitmax sites; a missing file is non-fatal (they
-- then have no donors and report "traitmax_no_templates"). Called once at
-- startup from bee_keeper_manager_run.lua.
function M.loadTemplates(config, path)
  local parsed = Templates.load(path or "bee_templates.dat")
  if not parsed then return nil, "not_found" end
  config.templates = parsed
  return parsed
end

-- ============================================================
-- Global program phases (bee_program.lua): a PROGRAM sequences phases across the
-- WHOLE apiary array (traitmax -> rainbow -> ...), advancing when a phase's goal
-- is met. Opt-in: set config.program = Program.new(phases) (M.initProgram). While
-- a program is active it dictates every site's mode this cycle.
-- ============================================================

-- Initialize the program state from config.programPhases (or the default), once.
function M.initProgram(config)
  config.program = config.program or Program.new(config.programPhases)
  return config.program
end

-- The COVERABLE target traits given the species reachable from the leaves we
-- currently hold -- the best allele set traitmax can achieve (the rest are
-- uncoverable: no reachable species carries a good allele for them).
local function coverableTraits(config, ownedLeaves)
  local plan = Traitmax.plan(config.mutationGraph, ownedLeaves, config.templates or {},
    Cfg.activeTraits(), Cfg.isGoodValue)
  local unc = {}; for _, t in ipairs(plan.uncoverable) do unc[t] = true end
  local cov = {}
  for _, t in ipairs(Cfg.activeTraits()) do if not unc[t] then cov[#cov + 1] = t end end
  return cov
end

-- Whether a genome is homozygous-good on every trait in `cov` (empty cov -> the
-- max allele set is nothing to reach, treated as not-a-max-bee).
local function isCoverableGG(ind, cov)
  if #cov == 0 then return false end
  for _, t in ipairs(cov) do
    if not (Cfg.isGoodValue(t, ind.active[t]) and Cfg.isGoodValue(t, ind.inactive[t])) then
      return false
    end
  end
  return true
end

-- One storage pass for program-phase evaluation (navigates to storage). Returns:
--   summary       = { [species] = { purePrincesses, pureDrones } }  (rainbow banks)
--   coverable     = the coverable target traits (the max allele set)
--   maxBeeReached = some stored bee is homozygous-good on every coverable trait
--                   (traitmax's goal)
--   banked        = { [species]=true } species with a purebred princess banked
--   perfected     = { [species]=true } species with a stored bee that is BOTH
--                   species-pure AND coverable-GG (the perfect phase's goal)
function M.scanStorageForProgram(config)
  local out = { summary = {}, maxBeeReached = false, banked = {}, perfected = {}, coverable = {} }
  if #M.storagePositions(config) == 0 or not config.mutationGraph then return out end
  local bees = {} -- { {species, pure, ind}, ... }
  M.forEachStorageStack(config, function(_pos, _slot, stack)
    local c = classifyBee(stack)
    if c then
      local rec = out.summary[c.species] or { purePrincesses = 0, pureDrones = 0 }
      out.summary[c.species] = rec
      if c.pure and c.role == "princess" then rec.purePrincesses = rec.purePrincesses + c.size
      elseif c.pure and c.role == "drone" then rec.pureDrones = rec.pureDrones + c.size end
      if c.pure then out.banked[c.species] = true end
      bees[#bees + 1] = { species = c.species, pure = c.pure, ind = readIndividual(stack) }
    end
  end)
  local ownedLeaves = {}
  for sp in pairs(out.summary) do
    if (config.mutationGraph.leaves or {})[sp] then ownedLeaves[sp] = true end
  end
  out.coverable = coverableTraits(config, ownedLeaves)
  for _, b in ipairs(bees) do
    if isCoverableGG(b.ind, out.coverable) then
      out.maxBeeReached = true
      if b.pure then out.perfected[b.species] = true end -- pure species + all good = perfect
    end
  end
  return out
end

-- The next species to PERFECT: a reachable species that is banked (rainbow gave
-- it a purebred) but not yet perfected (no stored bee that is species-pure AND
-- coverable-GG). Deterministic (lexicographic). nil -> perfect phase complete.
local function perfectTarget(config, scan)
  local reachable = Rainbow.targetSet(config.mutationGraph, {}, config.rainbowTargetProvider)
  -- Also treat held leaves as reachable species to perfect.
  for sp in pairs(scan.banked) do reachable[sp] = reachable[sp] end
  local best
  for sp in pairs(scan.banked) do
    if not scan.perfected[sp] and (not best or sp < best) then best = sp end
  end
  return best
end

-- Evaluate the active program phase: if its goal is met, advance. Returns
--   (phaseMode, targetSpecies, coverableTraits) -- targetSpecies + coverable are
-- set only for the perfect phase (the species being perfected this cycle and the
-- trait set to imprint). nil phaseMode -> program done.
function M.evaluateProgram(config)
  local prog = config.program
  if not prog then return nil end
  local phase = Program.current(prog)
  if not phase then return nil end
  local scan = M.scanStorageForProgram(config)

  local complete, target = false, nil
  if phase == "traitmax" then
    complete = scan.maxBeeReached
  elseif phase == "rainbow" then
    complete = (rainbowTarget(config, scan.summary) == nil)
  elseif phase == "perfect" then
    target = perfectTarget(config, scan)
    complete = (target == nil) -- every reachable banked species is perfected
  end

  if complete then
    phase = Program.advance(prog)
    -- Recompute a target if we just entered the perfect phase.
    if phase == "perfect" then target = perfectTarget(config, scan) end
  end
  return phase, target, scan.coverable
end

-- ============================================================
-- Main cycle
-- ============================================================

-- Runs one full pass over every configured site: harvest, analyze, then
-- dispatch to the right mode's decision function. Sites are visited in
-- nearest-neighbor order from wherever the drone currently is (your
-- call -- direct flight, minimize travel, not fixed list order).
function M.runCycle(config)
  local log = {}

  -- Proactive, HIGH-PRIORITY honey restock -- config.honeyCount is a
  -- running estimate (persists on the config table across cycles),
  -- seeded by a real scan the first time it's unknown, then kept in
  -- sync incrementally: decremented once per successful analyze() (see
  -- M.analyzeWorkingSlots), and true-up'd via a fresh countHoneyInCargo()
  -- scan after any successful restock trip. Checked here BEFORE any
  -- site is even visited, so a low stock gets topped up first thing,
  -- rather than only reacting after a site's own analysis attempt
  -- already discovers cargo is empty (which, on real hardware, could
  -- mean re-scanning the wrong thing or missing a restock opportunity
  -- entirely -- reported: honey restocked successfully once, then
  -- stopped restocking on subsequent runs). config.honeyRestockThreshold
  -- (default 5) is a buffer, not zero -- a single visit can need
  -- several honey units at once (multiple unanalyzed bees), so topping
  -- up a little early avoids running out mid-visit.
  if config.honeyCount == nil then
    config.honeyCount = countHoneyInCargo()
  end
  if config.honeyCount <= (config.honeyRestockThreshold or 5) then
    -- The tracked estimate says low, but it's still just an estimate --
    -- confirmed on real hardware that it can drift from reality (it
    -- fetched more honey while a real re-scan would have shown 4 still
    -- sitting in cargo). Verify with an actual scan (cheap, no travel)
    -- and true the tracker up to it BEFORE committing to a whole trip
    -- to storage -- only actually go if the VERIFIED count is still at
    -- or below the threshold.
    config.honeyCount = countHoneyInCargo()
    if config.honeyCount <= (config.honeyRestockThreshold or 5) then
      print(string.format("[restock-diag] proactive check: verified honeyCount=%d <= threshold=%d, attempting restock",
        config.honeyCount, config.honeyRestockThreshold or 5))
      if M.restockHoney(config) then
        config.honeyCount = countHoneyInCargo()
        print("[restock-diag] proactive restock succeeded, honeyCount now " .. config.honeyCount)
      end
    end
  end

  -- GLOBAL PROGRAM: if one is configured, advance it when the current phase's
  -- goal is met and run EVERY site in the active phase's mode this cycle. The
  -- program spans the whole apiary array (traitmax -> rainbow -> ...); when it
  -- finishes, sites fall back to their own configured mode. Evaluated once per
  -- cycle before any site is visited (it does one storage scan; see
  -- M.scanStorageForProgram -- a candidate to throttle if trips get costly).
  if config.program then
    local phaseMode, target, coverable = M.evaluateProgram(config)
    if phaseMode then
      -- The "perfect" phase runs the bee_combine serial-imprint handler toward the
      -- current target species (M.runPerfectSite); other phases map to a site mode.
      for _, s in ipairs(config.sites) do
        s.mode = phaseMode
        if phaseMode == "perfect" then
          s.targetSpecies = target
          s.perfectTraits = coverable
        end
      end
      table.insert(log, string.format("[program] phase: %s%s (%d left)",
        phaseMode, target and (" -> " .. target) or "", Program.remaining(config.program)))
    else
      table.insert(log, "[program] complete")
    end
  end

  -- ONE pass per site -- harvest, analyze, then decide/act, all before
  -- moving on to the next apiary. Previously this was TWO full sweeps
  -- (harvest every site, THEN decide/act at every site), which meant an
  -- apiary that still needed a princess seeded or a drone loaded got
  -- left behind while every OTHER site was harvested first, only to be
  -- revisited later in the second sweep -- wasted travel, and looked
  -- like the robot "abandoning" a site that clearly still needed work.
  local orderedSites = Nav.orderByProximity(config.sites)

  for _, site in ipairs(orderedSites) do
    M.harvestSite(config, site)
    -- Cheap and position-independent (operates on the drone's own cargo)
    -- -- calling it once per site instead of once per cycle doesn't cost
    -- any extra travel, and means a bee just harvested at this site is
    -- immediately usable in this SAME site's decision below rather than
    -- waiting for the next site's pass.
    M.analyzeWorkingSlots(config)

    local status
    if site.mode == "traitmax" then
      -- Traitmax-via-mutation runs in TWO phases (see bee_traitmax.lua). Phase
      -- A "acquire": bank the donor species (whose default templates carry the
      -- good alleles) via the genebank scheduler -- the same path rainbow uses.
      -- Once every donor is banked, runGenebankSchedule sets site.traitmaxPhase
      -- = "combine" and the site falls through to Phase B: the existing quality
      -- breeding, which concentrates the now-available good alleles into one
      -- max bee (species-agnostic). Without templates/graph/genebank, traitmax
      -- is just plain quality breeding, exactly as before.
      if M.traitmaxAcquiring(config, site) then
        site.modeLabel = "traitmax/acquire" -- Phase A: breeding up the mutation tree for donor alleles
        status = M.runMutationSite(config, site)
      else
        site.modeLabel = "traitmax/combine" -- Phase B: concentrating good alleles into one max bee
        status = M.runQualitySite(config, site)
      end
    elseif site.mode == "species" then
      site.modeLabel = "species"
      status = M.runQualitySite(config, site)
    elseif site.mode == "perfect" then
      site.modeLabel = "perfect"
      status = M.runPerfectSite(config, site)
    elseif site.mode == "mutation" or site.mode == "rainbow" then
      site.modeLabel = site.mode
      status = M.runMutationSite(config, site)
    else
      status = "unknown_mode:" .. tostring(site.mode)
    end
    table.insert(log, string.format("[%s] %s: %s", site.mode, site.name or "?", status))

    -- Catch anything the decide-phase itself just produced (a queen's
    -- FINAL work tick creates her offspring/output immediately, inside
    -- runQualitySite/runMutationSite's own getBeeProgress call, which
    -- runs AFTER harvestSite above in this same visit). Without this,
    -- freshly bred output sits unharvested for a full extra cycle even
    -- though the robot is still standing right there -- it only gets
    -- picked up the NEXT time this apiary happens to be visited again.
    -- No extra travel: gotoSite/harvestSite is a no-op if there's
    -- nothing new to harvest.
    M.harvestSite(config, site)
  end

  -- Cheap, no travel -- pure cargo bookkeeping. Catches anything that
  -- couldn't merge earlier (e.g. a freshly-analyzed bee alongside an
  -- already-analyzed matching stack from a different batch) once per
  -- cycle, after all this cycle's harvesting/analyzing/breeding is
  -- done.
  M.consolidateCargo(config)

  -- If any site came up genuinely empty-handed this cycle, storage might
  -- still have something usable sitting in it -- one bounded trip (not
  -- per-site) pulls bees back into cargo so the NEXT cycle's decisions
  -- actually see them, instead of storage being a one-way trip nothing
  -- ever gets read back from.
  local needsRestock = false
  for _, entry in ipairs(log) do
    if entry:find("no_candidate_drones_in_working_slots", 1, true)
      or entry:find("no_princess_at_site_or_in_cargo", 1, true)
      -- Mutation sites starve the same way: a parent species (princess or
      -- drone) the next tree step needs may be sitting in storage, not
      -- cargo. Without this, a mutation run can deadlock waiting on a
      -- parent it already owns -- e.g. 7 Forest princesses in storage while
      -- cargo has none, so the Forest x Wintry step never fires.
      or entry:find("waiting_on_parent_species", 1, true)
      -- Genebank scheduler "blocked" means it needs stock (a pristine base
      -- princess, usually) that may be sitting in storage -- pull it back.
      or entry:find("blocked", 1, true) then
      needsRestock = true
    end
  end
  if needsRestock then
    local restocked = M.restockFromStorage(config)
    if restocked > 0 then
      table.insert(log, string.format("[restock] pulled %d bee(s) back from storage", restocked))
    end
  end

  if config.needCharge == nil or config.needCharge then
    if Nav.needCharge(config.chargeThreshold) then
      Nav.chargeAtHome(config.chargerPos)
    end
  end

  return log
end

return M
