--[[
  Config for bee_keeper_manager.lua / bee_keeper_manager_run.lua. Plain Lua
  table (not a serialized data file), so it can have comments and be
  hand-edited directly.

  Site POSITIONS come from bee_keeper_setup.lua's area scan (persisted to
  bee_keeper_sites.dat) -- you don't list them here. What you DO configure
  here is what each discovered site should be doing (siteOverrides, keyed
  by the "siteN" name the scan assigned) -- anything left unassigned
  defaults to "traitmax".
--]]

return {
  -- Slot holding honey/honeydew stock for beekeeper.analyze(). Absolute
  -- last resort only -- M.analyzeWorkingSlots searches cargo for honey
  -- by item name first, and if cargo genuinely has none, automatically
  -- flies to honeyStoragePos (or storagePos, below) and fetches more.
  honeySlot = 1,

  -- Optional: a separate location to fetch honey from if you keep it
  -- apart from general storage. Leave nil to just reuse storagePos.
  honeyStoragePos = nil,

  -- Slots used as the live candidate-bee pool (the agent's own cargo).
  -- Leave nil -- M.resolveWorkingSlots auto-derives this as "every slot
  -- from 1 to the robot's real inventory size except honeySlot" via
  -- getInventorySize(), so it actually uses every slot an Inventory
  -- Upgrade gives you instead of a fixed guess. Only set this list
  -- explicitly if you need to reserve additional slots (equipment, etc.)
  -- beyond just honeySlot.
  workingSlots = nil,

  -- Where an apiary's offspring/product output (combs, drones, the
  -- replacement princess) lives. Leave nil -- M.harvestSite auto-derives
  -- this as "every slot from 3 to the apiary's real reported size" via
  -- getInventorySize(), which is what actually matches real hardware
  -- (confirmed via probeInventoryBelow(): the old hardcoded 7-15 guess,
  -- inherited from beeManager.lua's Transposer-based version, was wrong
  -- -- product was actually sitting in slots 3-6). Only set this if you
  -- need to override the auto-derived range for some reason.
  productSlots = nil,

  -- Forwarded to bee_breeding.lua's planGeneration -- how many independent
  -- drone-sources of a good allele to keep on hand per trait (default 2 if
  -- omitted). See bee_breeding.lua's shouldBank docs.
  minCopies = 2,

  -- Optional: what to do with a drone the algorithm doesn't want to keep.
  -- If left nil, discarded drones are automatically flown to trashPos (if
  -- set) or storagePos otherwise, and dropped there (see M.dumpToTrash /
  -- M.dumpToStorage) -- trash is preferred when both are known, since a
  -- breeding program generates a steady stream of unwanted drones that
  -- would otherwise slowly fill up a finite storage chest. Set this to a
  -- function(bee) to route them elsewhere instead (sampler/furnace).
  onDiscard = nil,

  -- How many slots to try in the storage container before giving up on a
  -- discard. Confirmed 27 via getInventorySize() -- a single chest.
  storageSlotCount = 27,

  -- Trash cans (e.g. Extra Utilities' Trash Can) typically expose a
  -- single always-empty inventory slot -- anything dropped in is voided
  -- immediately.
  trashSlotCount = 1,

  -- Block names the area scan (bee_keeper_setup.lua) treats as "this is an
  -- apiary" / "this is the storage container" / "this is the trash can",
  -- matched against geolyzer.analyze(sides.down).name. "Forestry:apiculture"
  -- confirmed via probeBlockBelow() against a real apiary -- note the
  -- capital F, and "apiculture" not "apiary" (both wrong in the earlier
  -- guess). If you also use an Alveary or Industrial Apiary, probe one of
  -- those too -- no reason to assume they report the same name. Add any
  -- storage container's real block name here the same way --
  -- "etfuturum:barrel" was added after the scan failed to recognize a
  -- barrel as storage. "ExtraUtilities:trashcan" is an UNCONFIRMED GUESS
  -- for Extra Utilities' Trash Can -- verify with probeBlockBelow() the
  -- same way before relying on it.
  apiaryBlockNames = {
    "Forestry:apiculture",
  },
  storageBlockNames = {
    "minecraft:chest",
    "minecraft:trapped_chest",
    "etfuturum:barrel",
  },
  trashBlockNames = {
    "ExtraUtilities:trashcan",
  },

  -- Whether bee_keeper_setup.lua flies the 4 corners (with a light flash)
  -- before scanning, in addition to the printed ASCII preview. Costs a
  -- little travel time up front.
  showBorderPreview = true,

  -- Charger position (dead-reckoned x,z, same origin as Nav.setHome) and
  -- whether to auto-return there when low on charge each cycle.
  needCharge = true,
  chargeThreshold = 0.2,
  chargerPos = { x = 0, z = 0 },

  -- Genebank: per-species purebred reserves that keep a breeding program from
  -- ever losing a species (see bee_genebank.lua / docs). Opt-in -- set this table
  -- to enable reserve gating in mutation mode; leave nil for the plain flow.
  genebank = {
    minPrincesses = 1,   -- purebred princesses kept per species (never spent)
    minDrones = 8,       -- purebred drones kept per species (maintenance target)
    recoveryDrones = 2,  -- min drones to safely re-purify after spending a princess

    -- Naturally-spawning "spare" princesses used to breed WORKING princesses of
    -- a species (converted against that species' bank drones), so the bank's own
    -- purebred princess is never spent/converted. Only these are consumed as
    -- fodder. (Provided by the user; expand as needed.)
    breederSpecies = {
      "Unusual", "Forest", "Modest", "Tropical", "Wintry",
      "Marshy", "Sorcerous", "Mystical", "Rocky", "Ocean",
    },

    -- Only PRISTINE princesses/queens may be used as breeders/spares -- ignoble
    -- ones degrade (lower lifetime, can't sustain a line), so they're never used
    -- as fodder. (Detection of pristine vs ignoble is a TODO -- pending the
    -- dominance/genome probe showing how the OC API surfaces it.)
    pristineOnly = true,
  },

  -- Storage backend for genebanks: "shared" (a normal chest at storagePos, the
  -- default) or "ae2" (an ME network via an me_interface component). See
  -- bee_storage.lua.
  storageBackend = "shared",

  -- DEPRECATED / unused: mutation recipes now come from the committed
  -- bee_mutations.dat dump, loaded into config.mutationGraph at startup by
  -- bee_keeper_manager_run.lua (see M.loadMutationGraph). Left here only so
  -- old configs don't error; nothing reads it anymore.
  mutationFallback = {},

  -- What each discovered site (by the name the scan assigned -- "site1",
  -- "site2", ...) should be doing. Anything not listed here defaults to
  -- traitmax. Run bee_keeper_setup once first to find out what your sites
  -- are actually named, then fill this in.
  siteOverrides = {
    -- ["site1"] = { mode = "species", targetSpecies = "Sticky" },
    -- ["site2"] = { mode = "mutation", targetSpecies = "SomeNewSpecies" },
  },

  -- storagePos/trashPos get filled in by bee_keeper_setup.lua's scan
  -- automatically (see bee_keeper_manager_run.lua) -- leave nil here.
  storagePos = nil,
  trashPos = nil,

  -- sites gets filled in by bee_keeper_manager_run.lua from the persisted
  -- scan + siteOverrides above (see M.loadSites) -- leave nil here.
  sites = nil,
}
