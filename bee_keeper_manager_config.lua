--[[
  Example config for bee_keeper_manager.lua. Edit and rename/require as
  needed -- this is a plain Lua table (not a serialized data file), so it
  can have comments and be hand-edited directly.
--]]

local sides = require("sides")

return {
  -- Slot holding honey/honeydew stock for beekeeper.analyze(). Restock
  -- this manually for now (or wire up a refill step once movement/storage
  -- access is built).
  honeySlot = 1,

  -- Slots used as the live candidate-bee pool (the agent's own cargo).
  -- Keep honeySlot and any equipment slots out of this list.
  workingSlots = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },

  -- Where an apiary's offspring/product output lives (see beeManager.lua's
  -- old scanApiaries -- same slot range, different mechanism).
  productSlots = { 7, 8, 9, 10, 11, 12, 13, 14, 15 },

  -- Forwarded to bee_breeding.lua's planGeneration -- how many independent
  -- drone-sources of a good allele to keep on hand per trait (default 2 if
  -- omitted). See bee_breeding.lua's shouldBank docs.
  minCopies = 2,

  -- Optional: what to do with a drone the algorithm doesn't want to keep.
  -- Left nil for now -- discarded drones are just left in place. Wire this
  -- up to a sampler/furnace/junk routine later if you want them cleared
  -- automatically.
  onDiscard = nil,

  -- Optional static mutation fallback, same shape bee_housing.getBeeParents
  -- would return, keyed by target species name. Only consulted if the live
  -- bee_housing lookup isn't reachable (see bee_keeper_manager.lua's
  -- header notes on this being unconfirmed for a moving agent).
  mutationFallback = {
    -- ["NewSpeciesName"] = {
    --   { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
    -- },
  },

  -- Each apiary the agent manages. `side` is relative to wherever the
  -- agent ends up sitting for that site (see Nav.gotoSite -- currently a
  -- stub assuming the agent is already in position).
  sites = {
    { name = "traitmax-1", side = sides.north, mode = "traitmax" },
    { name = "sticky-purify", side = sides.south, mode = "species", targetSpecies = "Sticky" },
    { name = "new-species-attempt", side = sides.east, mode = "mutation", targetSpecies = "SomeNewSpecies" },
  },
}
