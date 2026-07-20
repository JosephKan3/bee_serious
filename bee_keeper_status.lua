--[[
  Bee Keeper Status
  ------------------
  Tiny shared mutable state: "what is the drone doing right now." Every
  module that does something worth showing on the live dashboard
  (bee_keeper_manager.lua, bee_keeper_nav.lua) calls M.setStep(text) at the
  point it starts that action. Since `require` caches modules, every
  caller gets the SAME table -- no need to thread a status object through
  every function signature just to support an optional UI.

  bee_keeper_ui.lua polls M.get() each redraw; nothing here talks to a
  screen or GPU.
--]]

local M = {
  step = "idle",
  updatedAt = 0,
  history = {},
}

M.HISTORY_LIMIT = 8

-- Optional: set to a function() to be notified every time the step
-- changes -- bee_keeper_manager_run.lua uses this to drive live dashboard
-- redraws without any threading (every Status.setStep call already
-- happens at a meaningful action boundary throughout
-- bee_keeper_manager.lua/bee_keeper_nav.lua).
M.onChange = nil

-- Records the current action and appends it to a short rolling history
-- (shown as a log tail on the dashboard).
function M.setStep(text)
  M.step = text
  M.updatedAt = os.time()
  table.insert(M.history, text)
  while #M.history > M.HISTORY_LIMIT do
    table.remove(M.history, 1)
  end
  if M.onChange then
    M.onChange()
  end
end

function M.get()
  return { step = M.step, updatedAt = M.updatedAt, history = M.history }
end

return M
