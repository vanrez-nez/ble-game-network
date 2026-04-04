local config = require("ble_net.config")

local M = {}

local limits = config.limits

function M.set_limits(resolved)
  limits = resolved
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function has_control_characters(value)
  for i = 1, #value do
    local byte = value:byte(i)
    if byte and ((byte >= 0 and byte <= 8) or (byte >= 11 and byte <= 31) or byte == 127) then
      return true
    end
  end
  return false
end

function M.trimmed(value)
  return trim(value)
end

function M.non_empty_string(value)
  local normalized = trim(value)
  if normalized == "" then
    return nil, "empty"
  end
  return normalized
end

function M.room_name(value)
  local normalized, reason = M.non_empty_string(value)
  if not normalized then
    return nil, reason
  end

  if #normalized > limits.room_name_length then
    return nil, "too_long"
  end

  if has_control_characters(normalized) then
    return nil, "invalid_chars"
  end

  return normalized
end

function M.room_type(value)
  local normalized, reason = M.non_empty_string(value)
  if not normalized then
    return nil, reason
  end

  if #normalized > 3 then
    return nil, "too_long"
  end

  if normalized:find(":") then
    return nil, "invalid_chars"
  end

  if has_control_characters(normalized) then
    return nil, "invalid_chars"
  end

  return normalized:upper()
end

function M.room_id(value)
  local normalized, reason = M.non_empty_string(value)
  if not normalized then
    return nil, reason
  end

  if has_control_characters(normalized) then
    return nil, "invalid_chars"
  end

  return normalized
end

function M.max_clients(value)
  local number = tonumber(value)
  if not number then
    return nil, "invalid"
  end

  local integer = math.floor(number)
  if integer < limits.min_clients or integer > limits.max_clients then
    return nil, "out_of_range"
  end

  return integer
end

function M.transport(value, transport_enum)
  if value == transport_enum.RELIABLE or value == transport_enum.RESILIENT then
    return value
  end

  return nil, "invalid"
end

function M.text_payload(value)
  local normalized, reason = M.non_empty_string(value)
  if not normalized then
    return nil, reason
  end

  if #normalized > limits.text_payload_length then
    return nil, "too_long"
  end

  if has_control_characters(normalized) then
    return nil, "invalid_chars"
  end

  return normalized
end

return M
