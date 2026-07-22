--[[
  Bee Storage
  ------------
  A small STORAGE ABSTRACTION so the genebank/library layer doesn't care whether
  purebred banks live in a plain chest the robot flies to or in an AE2 network.
  Two backends, chosen by config:

    - "shared"  -- a normal storage inventory (the existing storagePos chest),
                   accessed by flying above it and using inventory_controller.
    - "ae2"     -- an AE2 ME network via an me_interface component (read side
                   grounded in ../waterline: getItemsInNetwork etc.). Physical
                   fetch/deposit out of AE2 is a later probe (Phase 4) and errors
                   clearly until then, so a misconfiguration fails loud, not silent.

  The abstraction is deliberately THIN and genome-agnostic -- it moves and lists
  raw stacks by an opaque `ref`; classifying a bee's species/role/purity is the
  caller's job (manager, via bee_trait_config / bee_breeding). Backends take their
  hardware accessors by DEPENDENCY INJECTION (a `deps` table) so they run against
  fakes in tests, exactly like bee_keeper_manager_test.lua's mocked world.

  Interface (every backend):
    b:snapshot()            -> { { ref=<opaque>, stack=<rawStack> }, ... }
                               all bee-like stacks currently in the store.
    b:fetch(ref, cargoSlot) -> bool   move that stack into the given cargo slot.
    b:deposit(cargoSlot)    -> bool   move the cargo slot's stack into the store.
    b.kind                  -> "shared" | "ae2"
--]]

local Storage = {}

-- Default bee classifier: a stack is "bee-like" if it carries an individual
-- genome, OR its item name looks like a Forestry bee (princess/queen/drone/bee).
-- Overridable via deps.isBee for odd item names.
local function defaultIsBee(stack)
  if not stack or not stack.name then return false end
  if stack.individual then return true end
  local n = stack.name:lower()
  return n:find("bee") ~= nil or n:find("princess") ~= nil
    or n:find("queen") ~= nil or n:find("drone") ~= nil
end

-- ============================================================
-- Shared-chest backend
-- ============================================================
--
-- deps (all injectable; the manager wires its real Nav/inventory_controller/
-- robot accessors here, tests wire an in-memory fake):
--   arrive()                 -> bool     travel so the store is the inventory below
--   size()                   -> number   external inventory slot count (side=down)
--   peek(slot)               -> stack|nil
--   pull(slot, cargoSlot, n) -> number   move n from external slot -> cargo slot
--   push(cargoSlot, slot)    -> bool     move cargo slot -> external slot
--   firstFreeExternal()      -> slot|nil first empty external slot (for deposit)
--   isBee(stack)             -> bool     (optional; defaults to defaultIsBee)
function Storage.sharedChest(deps)
  assert(deps and deps.arrive and deps.size and deps.peek and deps.pull and deps.push,
    "sharedChest backend requires arrive/size/peek/pull/push deps")
  local isBee = deps.isBee or defaultIsBee

  local b = { kind = "shared" }

  function b:snapshot()
    local out = {}
    if not deps.arrive() then return out end
    local n = deps.size() or 0
    for slot = 1, n do
      local stack = deps.peek(slot)
      if isBee(stack) then
        table.insert(out, { ref = slot, stack = stack })
      end
    end
    return out
  end

  function b:fetch(ref, cargoSlot)
    if not deps.arrive() then return false end
    local moved = deps.pull(ref, cargoSlot, 1)
    return (moved or 0) > 0
  end

  function b:deposit(cargoSlot)
    if not deps.arrive() then return false end
    local slot = deps.firstFreeExternal and deps.firstFreeExternal() or nil
    -- Fall back to a linear scan for an empty external slot if no helper given.
    if not slot then
      local n = deps.size() or 0
      for s = 1, n do
        if deps.peek(s) == nil then slot = s; break end
      end
    end
    if not slot then return false end
    return deps.push(cargoSlot, slot) and true or false
  end

  return b
end

-- ============================================================
-- AE2 backend (read side working; physical fetch/deposit = Phase 4 probe)
-- ============================================================
--
-- deps:
--   me()      -> me_interface proxy (defaults to component.me_interface)
--   isBee     -> optional classifier
--
-- snapshot() lists bee-like items in the network. AE2 stacks by NBT, so each
-- distinct bee genome is its own network entry (ref = a descriptor the fetch
-- path will use). getItemsInNetwork returns { name, label, size, damage, ... }.
function Storage.ae2(deps)
  deps = deps or {}
  local isBee = deps.isBee or defaultIsBee
  local b = { kind = "ae2" }

  local function me()
    if deps.me then return deps.me() end
    local component = require("component")
    return component.me_interface
  end

  function b:snapshot()
    local out = {}
    local iface = me()
    if not iface then return out end
    local items = iface.getItemsInNetwork() or {}
    for _, it in ipairs(items) do
      if isBee(it) then
        table.insert(out, { ref = { name = it.name, damage = it.damage, label = it.label }, stack = it })
      end
    end
    return out
  end

  -- Physically exporting a specific bee OUT of an ME network into the robot's
  -- inventory is NOT covered by the waterline read API and needs a real probe on
  -- hardware (Export Bus vs interface inventory vs database export). Until that
  -- Phase-4 probe, these fail loud rather than silently doing nothing.
  function b:fetch(_ref, _cargoSlot)
    error("ae2 backend: fetch not implemented yet (Phase 4 -- needs an AE2 export probe)")
  end
  function b:deposit(_cargoSlot)
    error("ae2 backend: deposit not implemented yet (Phase 4 -- needs an AE2 import probe)")
  end

  return b
end

-- ============================================================
-- Factory
-- ============================================================

-- config.storageBackend: "shared" (default) | "ae2". deps is the injected
-- hardware-accessor table for the chosen backend (see each constructor).
function Storage.new(config, deps)
  local kind = (config and config.storageBackend) or "shared"
  if kind == "ae2" then return Storage.ae2(deps) end
  if kind == "shared" then return Storage.sharedChest(deps) end
  error("unknown storageBackend: " .. tostring(kind))
end

Storage.defaultIsBee = defaultIsBee
return Storage
