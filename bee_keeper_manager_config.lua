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
  -- Slot holding honey/honeydew stock for beekeeper.analyze(). Restock
  -- this manually for now.
  honeySlot = 1,

  -- Slots used as the live candidate-bee pool (the agent's own cargo).
  -- Keep honeySlot and any equipment slots out of this list.
  workingSlots = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },

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
  -- If left nil AND storagePos is set (see below), discarded drones are
  -- automatically flown to storage and dropped (M.dumpToStorage). Set this
  -- to a function(bee) to route them elsewhere instead (sampler/furnace).
  onDiscard = nil,

  -- How many slots to try in the storage container before giving up on a
  -- discard. Confirmed 27 via getInventorySize() -- a single chest.
  storageSlotCount = 27,

  -- Block names the area scan (bee_keeper_setup.lua) treats as "this is an
  -- apiary" / "this is the storage container", matched against
  -- geolyzer.analyze(sides.down).name. "Forestry:apiculture" confirmed via
  -- probeBlockBelow() against a real apiary -- note the capital F, and
  -- "apiculture" not "apiary" (both wrong in the earlier guess). If you
  -- also use an Alveary or Industrial Apiary, probe one of those too --
  -- no reason to assume they report the same name. Add any storage
  -- container's real block name here the same way -- "etfuturum:barrel"
  -- was added after the scan failed to recognize a barrel as storage.
  apiaryBlockNames = {
    "Forestry:apiculture",
  },
  storageBlockNames = {
    "minecraft:chest",
    "minecraft:trapped_chest",
    "etfuturum:barrel",
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

  -- Optional static mutation fallback, same shape bee_housing.getBeeParents
  -- would return, keyed by target species name. Only consulted if the live
  -- bee_housing lookup isn't reachable (see bee_keeper_manager.lua's
  -- header notes on this being unconfirmed for a moving agent).
  mutationFallback = {
    -- ["NewSpeciesName"] = {
    --   { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
    -- },
  },

  -- What each discovered site (by the name the scan assigned -- "site1",
  -- "site2", ...) should be doing. Anything not listed here defaults to
  -- traitmax. Run bee_keeper_setup once first to find out what your sites
  -- are actually named, then fill this in.
  siteOverrides = {
    -- ["site1"] = { mode = "species", targetSpecies = "Sticky" },
    -- ["site2"] = { mode = "mutation", targetSpecies = "SomeNewSpecies" },
  },

  -- storagePos gets filled in by bee_keeper_setup.lua's scan automatically
  -- (see bee_keeper_manager_run.lua) -- leave nil here.
  storagePos = nil,

  -- sites gets filled in by bee_keeper_manager_run.lua from the persisted
  -- scan + siteOverrides above (see M.loadSites) -- leave nil here.
  sites = nil,
}
