local ble = (love and love.ble) or require("love.ble")
local config = require("ble_net.config")
local dedup = require("ble_net.dedup")
local validation = require("ble_net.validation")

local transport = {}
for k, v in pairs(ble.TRANSPORT) do transport[k] = v end
transport.NORMAL = ble.TRANSPORT.RELIABLE

local M = {
  TRANSPORT = transport,
  config = config,
  dedup = dedup,
  validation = validation,
}

local function classify_diagnostic(msg)
  if not msg then return nil, nil end
  local s = tostring(msg)

  -- Connection events
  local dev = s:match("server connection state: device=(%S+)")
  if dev then
    if s:match("state=2") then return "connection", "Client connected" end
    if s:match("state=0") then
      local st = s:match("status=(%d+)") or "?"
      return "connection", "Client disconnected (status " .. st .. ")"
    end
  end
  dev = s:match("client connection state: device=(%S+)")
  if dev then
    if s:match("state=2") then return "connection", "Connected to host" end
    if s:match("state=0") then
      local st = s:match("status=(%d+)") or "?"
      return "connection", "Disconnected from host (status " .. st .. ")"
    end
  end

  -- Reconnect
  if s:match("beginClientReconnect") then return "connection", "Reconnecting to host..." end
  if s:match("completeReconnectResume") then return "connection", "Reconnected" end
  if s:match("failReconnect") then return "connection", "Reconnection failed" end
  local gp = s:match("beginPeerReconnectGrace peer=(%S+)")
  if gp then return "connection", "Peer " .. gp .. " lost, waiting..." end
  local ep = s:match("expirePeerReconnectGrace peer=(%S+)")
  if ep then return "connection", "Peer " .. ep .. " timed out" end
  local rp = s:match("peer reconnected peer=(%S+)")
  if rp then return "connection", "Peer " .. rp .. " reconnected" end

  -- HELLO / binding
  local hp = s:match("received HELLO from peer=(%S+)")
  if hp then return "connection", "Peer " .. hp .. " joined" end

  -- Heartbeat
  if s:match("heartbeat re%-broadcast") then return "heartbeat", "Heartbeat" end

  -- Messages (host received)
  local hfrom, htype = s:match("host received packet.-from=(%S+).-type=(%S+)")
  if hfrom and htype then return "message", "Recv " .. htype .. " from " .. hfrom end
  -- Messages (client received)
  local cfrom, ctype = s:match("client received packet.-from=(%S+).-type=(%S+)")
  if cfrom and ctype then return "message", "Recv " .. ctype .. " from " .. cfrom end
  -- Messages (encode/send)
  local etype = s:match("encodePacket.-kind=data.-type=(%S+)")
  if etype then return "message", "Send " .. etype end
  -- Messages (queue/relay)
  local qt = s:match("client enqueuePacket.-type=(%S+)")
  if qt then return "message", "Queued " .. qt end
  local rt = s:match("host enqueueNotification.-type=(%S+)")
  if rt then return "message", "Relay " .. rt end

  -- Session
  if s:match("host button pressed") then return "session", "Starting host..." end
  if s:match("scan button pressed") then return "session", "Starting scan..." end
  if s:match("^join room") or s:match("^connectToRoom") then return "session", "Joining room..." end
  if s:match("leave button pressed") then return "session", "Leaving session" end
  if s:match("^completeLocalJoin") then return "session", "Joined session" end
  if s:match("advertise adv") then return "session", "Advertising room" end

  -- Scan
  if s:match("scan started") then return "scan", "Scanning..." end
  local rn = s:match("onScanResult.-name=(%S+)")
  if rn and rn ~= "" then return "scan", "Room found: " .. rn end

  -- Everything else: drop
  return nil, nil
end

local function default_state(title)
  return {
    rooms = {},
    peers = {},
    messages = {},
    notices = {},
    diagnostics = {},
    device_address = "",
    session_id = nil,
    transport = nil,
    status = "Idle",
    title = title or config.defaults.title,
    in_session = false,
    local_id = "",
    is_host = false,
    peer_statuses = {},
  }
end

function M.new(opts)
  local settings = config.resolve(opts)
  local self = {}
  local state = default_state(settings.defaults.title)
  local room_name = validation.room_name(settings.defaults.room_name) or config.defaults.room_name
  local max_clients = validation.max_clients(settings.defaults.max_clients) or config.defaults.max_clients
  local debug_prefix = settings.defaults.debug_prefix
  local debug_enabled = settings.defaults.debug_enabled
  local limits = settings.limits
  local windows = settings.windows
  validation.set_limits(limits)
  local event_handler = nil

  local notice_dedup = dedup.new({
    max_age = windows.notice_dedup_seconds,
    max_count = limits.dedup_entries,
  })

  local function debug_log(text)
    if not debug_enabled then
      return
    end

    print(debug_prefix .. " " .. text)
  end

  local function room_by_id(room_id)
    for i = 1, #state.rooms do
      if state.rooms[i].room_id == room_id then
        return i
      end
    end
    return nil
  end

  local function set_roster(peers)
    state.peers = peers or {}
  end

  function self.transport_name(value)
    if value == ble.TRANSPORT.RESILIENT then
      return "Resilient"
    end
    return "Normal"
  end

  function self.address_text()
    return (state.device_address ~= "" and state.device_address) or "n/a"
  end

  function self.diagnostics_meta_lines()
    return {
      "Address: " .. self.address_text(),
    }
  end

  function self.room_summary_text(room)
    return self.transport_name(room.transport) .. "  |  peers " .. tostring(room.peer_count) .. "/" .. tostring(room.max)
  end

  function self.room_signal_text(room)
    return "RSSI " .. tostring(room.rssi)
  end

  function self.session_info_lines()
    return {
      "ID: " .. tostring(state.session_id),
      "Transport: " .. self.transport_name(state.transport),
      "Local Peer: " .. ((state.local_id ~= "" and state.local_id) or "?"),
      "Role: " .. (state.is_host and "Host" or "Client"),
      "Status: " .. tostring(state.status),
    }
  end

  function self.push_notice(text)
    local normalized = tostring(text or "")
    debug_log("notice: " .. text)
    if not notice_dedup:record(normalized) then
      state.status = normalized
      return false
    end

    state.notices[#state.notices + 1] = normalized
    if #state.notices > limits.notices then
      table.remove(state.notices, 1)
    end
    state.status = normalized
    return true
  end

  function self.push_message(author, text, kind)
    state.messages[#state.messages + 1] = {
      author = author,
      text = text,
      kind = kind or "remote",
    }
    if #state.messages > limits.messages then
      table.remove(state.messages, 1)
    end
  end

  function self.push_diagnostic(platform, text)
    local cat, friendly = classify_diagnostic(text)
    if not cat then return end
    local entry = {
      cat = cat,
      text = friendly,
      raw = "[" .. (platform or "?") .. "] " .. tostring(text or ""),
    }
    state.diagnostics[#state.diagnostics + 1] = entry
    if #state.diagnostics > limits.diagnostics then
      table.remove(state.diagnostics, 1)
    end
  end

  function self.refresh_live_state()
    if ble.local_id then
      state.local_id = ble.local_id() or ""
    end

    if ble.address then
      state.device_address = ble.address() or ""
    end

    if ble.is_host then
      state.is_host = ble.is_host()
    else
      state.is_host = false
    end

    if state.in_session and ble.peers then
      state.peers = ble.peers() or {}
    end
  end

  function self.reset_lobby()
    state.rooms = {}
    state.peers = {}
    state.messages = {}
    state.session_id = nil
    state.transport = nil
    state.in_session = false
    state.is_host = false
    state.peer_statuses = {}
    notice_dedup:reset()
    self.refresh_live_state()
  end

  function self.start_host(transport)
    local resolved_transport = validation.transport(transport, ble.TRANSPORT)
    if not resolved_transport then
      self.push_notice("Invalid transport for host")
      return false
    end

    self.reset_lobby()
    state.transport = resolved_transport
    state.status = "Starting host..."
    debug_log("host button pressed: " .. self.transport_name(resolved_transport))
    ble.host({
      room = room_name,
      max = max_clients,
      transport = resolved_transport,
    })
    return true
  end

  function self.start_scan()
    self.reset_lobby()
    state.status = "Scanning..."
    debug_log("scan button pressed")
    ble.scan()
  end

  function self.join_room(room_id, room_name)
    local resolved_room_id = validation.room_id(room_id)
    if not resolved_room_id then
      self.push_notice("Invalid room id")
      return false
    end

    local room_label = validation.room_name(room_name) or resolved_room_id or "room"
    state.status = "Joining " .. room_label .. "..."
    debug_log("join room: " .. tostring(resolved_room_id))
    ble.join(resolved_room_id)
    return true
  end

  function self.leave_session()
    debug_log("leave button pressed")
    ble.leave()
    self.reset_lobby()
    self.push_notice("Returned to idle")
  end

  function self.broadcast_payload(msg_type, payload)
    self.last_out = {
      msg_type = msg_type,
      payload = payload,
      time = love.timer.getTime(),
    }
    return ble.broadcast(msg_type, payload)
  end

  function self.send_payload(peer_id, msg_type, payload)
    if ble.send then
      return ble.send(peer_id, msg_type, payload)
    end
    return false
  end

  function self.set_event_handler(handler)
    event_handler = handler
  end

  function self.send_chat(text)
    local value = validation.text_payload(text)
    if not value or not state.in_session then
      return false, value
    end

    self.broadcast_payload("chat", {
      text = value,
    })

    debug_log("send chat: " .. value)
    self.push_message("you", value, "local")
    return true, value
  end

  function self.diagnostics_text()
    local lines = self.diagnostics_meta_lines()

    if #state.diagnostics > 0 then
      lines[#lines + 1] = ""
    end

    for i = 1, #state.diagnostics do
      local d = state.diagnostics[i]
      lines[#lines + 1] = type(d) == "table" and d.raw or tostring(d)
    end

    return table.concat(lines, "\n")
  end

  self.last_in = nil
  self.last_out = nil

  function self.handle_event(ev)
    debug_log("event: " .. tostring(ev.type))
    if ev.type == "message" then
      self.last_in = {
        msg_type = ev.msg_type,
        peer_id = ev.peer_id,
        payload = ev.payload,
        time = love.timer.getTime(),
      }
    end
    if ev.type == "room_found" then
      local idx = room_by_id(ev.room_id)
      if idx then
        state.rooms[idx] = ev
      else
        state.rooms[#state.rooms + 1] = ev
      end
      state.status = "Found " .. tostring(#state.rooms) .. " room(s)"

    elseif ev.type == "room_lost" then
      local idx = room_by_id(ev.room_id)
      if idx then
        table.remove(state.rooms, idx)
      end

    elseif ev.type == "hosted" then
      state.in_session = true
      state.session_id = ev.session_id
      state.transport = ev.transport
      set_roster(ev.peers)
      state.local_id = ev.peer_id or state.local_id
      state.is_host = true
      self.push_notice("Hosting " .. self.transport_name(ev.transport) .. " room")

    elseif ev.type == "joined" then
      state.in_session = true
      state.session_id = ev.session_id
      state.transport = ev.transport
      set_roster(ev.peers)
      state.local_id = ev.peer_id or state.local_id
      state.is_host = false
      self.push_notice("Joined room " .. ev.room_id)

    elseif ev.type == "peer_joined" then
      set_roster(ev.peers)
      self.push_notice(ev.peer_id .. " joined")

    elseif ev.type == "peer_left" then
      set_roster(ev.peers)
      state.peer_statuses[ev.peer_id] = nil
      self.push_notice(ev.peer_id .. " left (" .. ev.reason .. ")")

    elseif ev.type == "peer_status" then
      state.peer_statuses[ev.peer_id] = ev.status
      if ev.status == "reconnecting" then
        self.push_notice(ev.peer_id .. " reconnecting...")
      elseif ev.status == "connected" then
        self.push_notice(ev.peer_id .. " reconnected")
      end

    elseif ev.type == "message" then
      if ev.msg_type == "chat" then
        local text = ev.payload and ev.payload.text or "<non-text payload>"
        self.push_message(ev.peer_id, text, "remote")
      end

    elseif ev.type == "session_migrating" then
      state.in_session = true
      self.push_notice("Migrating to " .. ev.new_host_id .. "...")

    elseif ev.type == "session_resumed" then
      state.in_session = true
      state.session_id = ev.session_id or state.session_id
      set_roster(ev.peers)
      if state.local_id ~= "" then
        state.is_host = ev.new_host_id == state.local_id
      end
      self.push_notice("Session resumed on " .. ev.new_host_id)

    elseif ev.type == "session_ended" then
      self.push_notice("Session ended: " .. ev.reason)
      self.reset_lobby()

    elseif ev.type == "radio" then
      self.push_notice("Bluetooth state: " .. ev.state)

    elseif ev.type == "error" then
      self.push_notice("Error: " .. ev.code .. " - " .. ev.detail)

    elseif ev.type == "diagnostic" then
      self.push_diagnostic(ev.platform, ev.message)
    end

    self.refresh_live_state()

    if event_handler then
      event_handler(ev, self, state)
    end
  end

  function self.update()
    local events = ble.poll()
    for i = 1, #events do
      self.handle_event(events[i])
    end

    self.refresh_live_state()
  end

  function self.initialize()
    self.refresh_live_state()

    local radio = ble.state and ble.state() or "unknown"
    if radio == "unsupported" then
      self.push_notice("This build does not provide BLE on this platform")
    elseif radio == "unauthorized" then
      self.push_notice("Bluetooth permission is required")
    elseif radio == "off" then
      self.push_notice("Turn Bluetooth on to host or scan")
    end
  end

  self.state = state
  self.ble = ble

  return self
end

return M
