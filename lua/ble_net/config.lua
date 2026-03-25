local M = {}

M.defaults = {
  title = "BLE Demo Chat",
  room_name = "Demo Chat",
  max_clients = 4,
  debug_prefix = "[ble_net]",
  debug_enabled = true,
}

M.limits = {
  notices = 12,
  messages = 60,
  diagnostics = 80,
  room_name_length = 24,
  text_payload_length = 512,
  min_clients = 1,
  max_clients = 8,
  dedup_entries = 64,
}

M.windows = {
  notice_dedup_seconds = 1.5,
}

local function pick_explicit(current, fallback)
  if current ~= nil then
    return current
  end
  return fallback
end

function M.resolve(opts)
  opts = opts or {}

  local user = opts.config or {}
  local user_defaults = user.defaults or {}
  local user_limits = user.limits or {}

  return {
    defaults = {
      title = pick_explicit(opts.title, pick_explicit(user_defaults.title, M.defaults.title)),
      room_name = pick_explicit(opts.room_name, pick_explicit(user_defaults.room_name, M.defaults.room_name)),
      max_clients = pick_explicit(opts.max_clients, pick_explicit(user_defaults.max_clients, M.defaults.max_clients)),
      debug_prefix = pick_explicit(opts.debug_prefix, pick_explicit(user_defaults.debug_prefix, M.defaults.debug_prefix)),
      debug_enabled = pick_explicit(opts.debug_enabled, pick_explicit(user_defaults.debug_enabled, M.defaults.debug_enabled)),
    },
    limits = {
      notices = pick_explicit(user_limits.notices, M.limits.notices),
      messages = pick_explicit(user_limits.messages, M.limits.messages),
      diagnostics = pick_explicit(user_limits.diagnostics, M.limits.diagnostics),
      room_name_length = pick_explicit(user_limits.room_name_length, M.limits.room_name_length),
      text_payload_length = pick_explicit(user_limits.text_payload_length, M.limits.text_payload_length),
      min_clients = pick_explicit(user_limits.min_clients, M.limits.min_clients),
      max_clients = pick_explicit(user_limits.max_clients, M.limits.max_clients),
      dedup_entries = pick_explicit(user_limits.dedup_entries, M.limits.dedup_entries),
    },
    windows = {
      notice_dedup_seconds = pick_explicit((user.windows or {}).notice_dedup_seconds, M.windows.notice_dedup_seconds),
    },
  }
end

return M
