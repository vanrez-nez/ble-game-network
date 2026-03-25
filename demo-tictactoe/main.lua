package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua;../lua/?.lua;../lua/?/init.lua"

local ble_net = require("ble_net")
local network = ble_net.new({
  title = "BLE Tic-Tac-Toe",
  room_name = "Tic-Tac-Toe",
  max_clients = 6,
  debug_prefix = "[demo-tictactoe]",
})

local palette = {
  bg = {0.07, 0.09, 0.12},
  panel = {0.11, 0.14, 0.18},
  panel_alt = {0.15, 0.19, 0.24},
  stroke = {0.24, 0.29, 0.35},
  accent = {0.97, 0.62, 0.28},
  accent_soft = {0.96, 0.79, 0.57},
  text = {0.95, 0.96, 0.98},
  dim = {0.61, 0.67, 0.75},
  success = {0.36, 0.82, 0.57},
  danger = {0.90, 0.36, 0.35},
}

local app = network.state
local ui = {
  diagnostics_open = false,
  diagnostics_scroll = 0,
  diagnostics_view = nil,
  diagnostics_dragging = false,
  diagnostics_drag_last_y = 0,
}

local game = {
  board = {"", "", "", "", "", "", "", "", ""},
  turn = "X",
  winner = nil,
  players = {
    X = nil,
    O = nil,
  },
  role = "viewer",
  status = "Host or join a room to begin.",
}

local buttons = {}
local fonts = {}
local debug_enabled = true

local winning_lines = {
  {1, 2, 3},
  {4, 5, 6},
  {7, 8, 9},
  {1, 4, 7},
  {2, 5, 8},
  {3, 6, 9},
  {1, 5, 9},
  {3, 5, 7},
}

local function debug_log(text)
  if debug_enabled then
    print("[demo-tictactoe] " .. text)
  end
end

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function layout_metrics(width, height)
  local margin = clamp(math.floor(width * 0.04), 14, 24)
  local gap = clamp(math.floor(width * 0.024), 10, 18)
  local topbar_h = clamp(math.floor(height * 0.095), 72, 88)
  return {
    margin = margin,
    gap = gap,
    radius = 18,
    topbar_h = topbar_h,
    button_h = clamp(math.floor(height * 0.06), 42, 50),
  }
end

local function safe_area()
  if love.window and love.window.getSafeArea then
    local x, y, w, h = love.window.getSafeArea()
    if x and y and w and h then
      return x, y, w, h
    end
  end

  local width, height = love.graphics.getDimensions()
  return 0, 0, width, height
end

local function board_copy(source)
  local copy = {}
  for i = 1, 9 do
    copy[i] = source[i] or ""
  end
  return copy
end

local function reset_local_game(status)
  game.board = {"", "", "", "", "", "", "", "", ""}
  game.turn = "X"
  game.winner = nil
  game.players.X = nil
  game.players.O = nil
  game.role = "viewer"
  game.status = status or "Waiting for host state..."
  app.status = game.status
end

local function symbol_name(symbol)
  if symbol == "X" then
    return "Player X"
  elseif symbol == "O" then
    return "Player O"
  elseif symbol == "draw" then
    return "Draw"
  end
  return "Viewer"
end

local function update_local_role()
  local previous_role = game.role

  if app.local_id ~= "" and app.local_id == game.players.X then
    game.role = "X"
  elseif app.local_id ~= "" and app.local_id == game.players.O then
    game.role = "O"
  else
    game.role = "viewer"
  end

  if previous_role ~= game.role and app.in_session then
    if game.role == "viewer" then
      network.push_notice("You are watching this round")
    else
      network.push_notice("You are " .. game.role)
    end
  end
end

local function describe_board_state()
  if not game.players.O then
    return "Waiting for a second player. Others can watch."
  end
  if game.winner == "draw" then
    return "Draw game."
  end
  if game.winner == "X" or game.winner == "O" then
    return symbol_name(game.winner) .. " wins."
  end
  return symbol_name(game.turn) .. " to move."
end

local function check_winner(board)
  for i = 1, #winning_lines do
    local line = winning_lines[i]
    local first = board[line[1]]
    if first ~= "" and first == board[line[2]] and first == board[line[3]] then
      return first
    end
  end

  for i = 1, 9 do
    if board[i] == "" then
      return nil
    end
  end

  return "draw"
end

local function host_peer_id()
  for i = 1, #app.peers do
    if app.peers[i].is_host then
      return app.peers[i].peer_id
    end
  end
  return nil
end

local function remote_peers()
  local peers = {}
  for i = 1, #app.peers do
    local peer = app.peers[i]
    if not peer.is_host then
      peers[#peers + 1] = peer.peer_id
    end
  end
  table.sort(peers)
  return peers
end

local function broadcast_state()
  game.status = describe_board_state()
  app.status = game.status
  update_local_role()
  network.broadcast_payload("ttt_state", {
    board = board_copy(game.board),
    turn = game.turn,
    winner = game.winner or "",
    status = game.status,
    players = {
      X = game.players.X or "",
      O = game.players.O or "",
    },
  })
end

local function host_reset()
  game.board = {"", "", "", "", "", "", "", "", ""}
  game.turn = "X"
  game.winner = nil
  broadcast_state()
end

local function sync_host_players()
  if not app.is_host then
    return
  end

  local remotes = remote_peers()
  local previous_x = game.players.X
  local previous_o = game.players.O

  game.players.X = app.local_id ~= "" and app.local_id or previous_x
  game.players.O = remotes[1]

  if previous_x ~= game.players.X or previous_o ~= game.players.O then
    host_reset()
  else
    broadcast_state()
  end
end

local function apply_state(payload)
  if type(payload) ~= "table" or type(payload.board) ~= "table" or type(payload.players) ~= "table" then
    network.push_notice("Invalid tic-tac-toe state payload")
    return
  end

  local next_board = {}
  for i = 1, 9 do
    local value = payload.board[i]
    if value ~= "" and value ~= "X" and value ~= "O" then
      network.push_notice("Invalid tic-tac-toe board value")
      return
    end
    next_board[i] = value or ""
  end

  if payload.turn ~= "X" and payload.turn ~= "O" then
    network.push_notice("Invalid tic-tac-toe turn")
    return
  end

  if payload.winner ~= "" and payload.winner ~= "X" and payload.winner ~= "O" and payload.winner ~= "draw" then
    network.push_notice("Invalid tic-tac-toe winner")
    return
  end

  game.board = next_board
  game.turn = payload.turn
  game.winner = payload.winner ~= "" and payload.winner or nil
  game.players.X = payload.players.X ~= "" and payload.players.X or nil
  game.players.O = payload.players.O ~= "" and payload.players.O or nil
  game.status = tostring(payload.status or describe_board_state())
  app.status = game.status
  update_local_role()
end

local function host_apply_move(actor_id, index)
  if not app.is_host then
    return
  end

  if type(index) ~= "number" or index < 1 or index > 9 then
    debug_log("invalid move index")
    return
  end

  if not game.players.O then
    network.push_notice("Waiting for a second player")
    return
  end

  if game.winner then
    network.push_notice("Round is over. Reset to play again.")
    return
  end

  local expected_peer = game.players[game.turn]
  if actor_id ~= expected_peer then
    network.push_notice("It is not your turn")
    return
  end

  if game.board[index] ~= "" then
    network.push_notice("That square is already taken")
    return
  end

  game.board[index] = game.turn
  game.winner = check_winner(game.board)
  if not game.winner then
    game.turn = game.turn == "X" and "O" or "X"
  end

  broadcast_state()
end

local function request_reset()
  if app.is_host then
    host_reset()
  else
    network.broadcast_payload("ttt_reset", {
      requested_by = app.local_id,
    })
  end
end

local function play_cell(index)
  if not app.in_session then
    return
  end

  if game.role == "viewer" then
    network.push_notice("Viewers cannot play")
    return
  end

  if game.role ~= game.turn then
    network.push_notice("Wait for your turn")
    return
  end

  if app.is_host then
    host_apply_move(app.local_id, index)
  else
    network.broadcast_payload("ttt_move", {
      index = index,
    })
  end
end

local function diagnostics_lines(max_width)
  local lines = {}
  for i = 1, #app.diagnostics do
    local _, wrapped = fonts.small:getWrap(app.diagnostics[i], max_width)
    if #wrapped == 0 then
      lines[#lines + 1] = ""
    else
      for j = 1, #wrapped do
        lines[#lines + 1] = wrapped[j]
      end
    end
  end
  return lines
end

local function adjust_diagnostics_scroll(delta)
  local view = ui.diagnostics_view
  if not view then
    return
  end

  ui.diagnostics_scroll = clamp(ui.diagnostics_scroll + delta, 0, view.max_scroll or 0)
end

local function start_host(transport)
  reset_local_game("Starting host...")
  network.start_host(transport)
end

local function start_scan()
  reset_local_game("Scanning...")
  network.start_scan()
end

local function leave_session()
  reset_local_game("Returned to lobby.")
  network.leave_session()
end

local function register_button(x, y, w, h, label, action, style)
  buttons[#buttons + 1] = {
    x = x,
    y = y,
    w = w,
    h = h,
    label = label,
    action = action,
    style = style or "default",
  }
end

local function draw_panel(x, y, w, h, radius, fill)
  love.graphics.setColor(fill or palette.panel)
  love.graphics.rectangle("fill", x, y, w, h, radius, radius)
  love.graphics.setColor(palette.stroke)
  love.graphics.rectangle("line", x, y, w, h, radius, radius)
end

local function draw_button(btn)
  local mx, my = love.mouse.getPosition()
  local hot = mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h
  local fill = palette.panel_alt
  local text = palette.text

  if btn.style == "accent" then
    fill = hot and palette.accent_soft or palette.accent
    text = {0.09, 0.08, 0.07}
  elseif btn.style == "danger" then
    fill = hot and {0.96, 0.49, 0.46} or palette.danger
    text = {0.09, 0.08, 0.07}
  elseif btn.style == "ghost" then
    fill = hot and {0.18, 0.23, 0.29, 0.96} or {0.11, 0.14, 0.18, 0.92}
    text = hot and palette.text or palette.dim
  elseif hot then
    fill = {0.20, 0.25, 0.31}
  end

  love.graphics.setColor(fill)
  love.graphics.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 14, 14)
  love.graphics.setColor(btn.style == "ghost" and palette.stroke or {0, 0, 0, 0.18})
  love.graphics.rectangle("line", btn.x, btn.y, btn.w, btn.h, 14, 14)
  love.graphics.setColor(text)
  love.graphics.setFont(fonts.body)
  love.graphics.printf(btn.label, btn.x + 10, btn.y + math.floor((btn.h - fonts.body:getHeight()) * 0.5), btn.w - 20, "center")
end

local function draw_topbar(width, metrics)
  draw_panel(0, 0, width, metrics.topbar_h, 0, palette.panel)
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.title)
  love.graphics.print(app.title, metrics.margin, 16)
end

local function draw_diagnostics_overlay(width, height, metrics)
  local margin = metrics.margin
  local safe_x, safe_y, safe_w = safe_area()
  local header_h = clamp(math.floor(height * 0.18), 108, 150)
  local log_x = margin
  local log_y = header_h
  local log_w = width - margin * 2
  local log_h = height - log_y - margin

  love.graphics.setColor(0.02, 0.03, 0.05, 0.98)
  love.graphics.rectangle("fill", 0, 0, width, height)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("BLE Diagnostics", margin, math.max(margin, safe_y + 6))

  register_button(safe_x + safe_w - margin - 176, math.max(margin - 2, safe_y + 4), 80, 34, "Copy", function()
    if love.system and love.system.setClipboardText then
      love.system.setClipboardText(network.diagnostics_text())
      network.push_notice("Diagnostics copied")
    else
      network.push_notice("Clipboard is unavailable on this platform")
    end
  end, "ghost")

  register_button(safe_x + safe_w - margin - 88, math.max(margin - 2, safe_y + 4), 88, 34, "Close", function()
    ui.diagnostics_open = false
    ui.diagnostics_dragging = false
  end, "danger")

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  local meta_y = math.max(margin, safe_y + 6) + 34
  local meta_w = width - margin * 2
  local meta = network.diagnostics_meta_lines()
  for i = 1, #meta do
    love.graphics.printf(meta[i], margin, meta_y, meta_w)
    meta_y = meta_y + fonts.small:getHeight() + 3
  end

  draw_panel(log_x, log_y, log_w, log_h, 14, palette.panel)

  local inner_x = log_x + 12
  local inner_y = log_y + 10
  local inner_w = log_w - 24
  local inner_h = log_h - 20
  local line_h = fonts.small:getHeight() + 2
  local lines = diagnostics_lines(inner_w)
  local visible = math.max(1, math.floor(inner_h / line_h))
  local max_scroll = math.max(0, #lines - visible)
  ui.diagnostics_scroll = clamp(ui.diagnostics_scroll, 0, max_scroll)

  ui.diagnostics_view = {
    x = log_x,
    y = log_y,
    w = log_w,
    h = log_h,
    line_h = line_h,
    max_scroll = max_scroll,
  }

  if #lines == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.printf("No BLE diagnostics yet.", inner_x, inner_y, inner_w)
    return
  end

  local start = math.max(1, #lines - visible - ui.diagnostics_scroll + 1)
  love.graphics.setColor(palette.text)
  love.graphics.setScissor(log_x + 1, log_y + 1, log_w - 2, log_h - 2)
  for i = start, math.min(#lines, start + visible - 1) do
    love.graphics.printf(lines[i], inner_x, inner_y, inner_w)
    inner_y = inner_y + line_h
  end
  love.graphics.setScissor()
end

local function draw_room_card(room, x, y, w, join_action)
  draw_panel(x, y, w, 106, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print(room.name, x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(network.room_summary_text(room), x + 16, y + 42, w - 32)
  love.graphics.printf(network.room_signal_text(room), x + 16, y + 60, w - 32)

  register_button(x + 16, y + 66, w - 32, 28, "Join Room", join_action)
end

local function draw_menu(width, height, metrics)
  local panel_x = metrics.margin
  local panel_y = metrics.topbar_h + metrics.gap
  local panel_w = width - metrics.margin * 2
  local panel_h = height - panel_y - metrics.margin

  draw_panel(panel_x, panel_y, panel_w, panel_h, metrics.radius, palette.panel)

  local cursor_y = panel_y + 18
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("Lobby", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 30
  love.graphics.setFont(fonts.body)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(
    "Host a room for a two-player tic-tac-toe match. Extra peers join as viewers and watch the board state live.",
    panel_x + 18,
    cursor_y,
    panel_w - 36
  )

  cursor_y = cursor_y + 64
  register_button(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Host Reliable", function()
    start_host(ble_net.TRANSPORT.RELIABLE)
  end, "accent")

  cursor_y = cursor_y + metrics.button_h + metrics.gap
  register_button(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Host Resilient", function()
    start_host(ble_net.TRANSPORT.RESILIENT)
  end, "accent")

  cursor_y = cursor_y + metrics.button_h + metrics.gap
  register_button(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Scan Rooms", start_scan)

  cursor_y = cursor_y + metrics.button_h + 18
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Status", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 28
  draw_panel(panel_x + 18, cursor_y, panel_w - 36, 54, 14, {0.10, 0.12, 0.15})
  love.graphics.setColor(palette.dim)
  love.graphics.setFont(fonts.body)
  love.graphics.printf(app.status, panel_x + 30, cursor_y + 10, panel_w - 60)

  cursor_y = cursor_y + 70
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Discovered Rooms", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 30
  if #app.rooms == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.setFont(fonts.body)
    love.graphics.printf("No rooms visible yet.", panel_x + 18, cursor_y, panel_w - 36)
    return
  end

  local max_cards = math.max(1, math.floor((panel_h - (cursor_y - panel_y) - 18) / 116))
  for i = 1, math.min(#app.rooms, max_cards) do
    local room = app.rooms[i]
    draw_room_card(room, panel_x + 18, cursor_y, panel_w - 36, function()
      network.join_room(room.room_id, room.name)
    end)
    cursor_y = cursor_y + 116
  end
end

local function player_line(symbol)
  local peer_id = game.players[symbol]
  if peer_id then
    return symbol .. ": " .. peer_id
  end
  return symbol .. ": waiting"
end

local function draw_board(x, y, size)
  local gap = 10
  local cell = math.floor((size - gap * 2) / 3)
  local start_x = x + math.floor((size - (cell * 3 + gap * 2)) * 0.5)
  local start_y = y + math.floor((size - (cell * 3 + gap * 2)) * 0.5)

  for row = 0, 2 do
    for col = 0, 2 do
      local index = row * 3 + col + 1
      local cell_x = start_x + col * (cell + gap)
      local cell_y = start_y + row * (cell + gap)
      local value = game.board[index]
      local fill = palette.panel_alt

      if value == "X" then
        fill = {0.97, 0.62, 0.28, 0.22}
      elseif value == "O" then
        fill = {0.36, 0.82, 0.57, 0.20}
      end

      draw_panel(cell_x, cell_y, cell, cell, 18, fill)

      register_button(cell_x, cell_y, cell, cell, "", function()
        play_cell(index)
      end, "ghost")

      if value ~= "" then
        love.graphics.setColor(value == "X" and palette.accent_soft or palette.success)
        love.graphics.setFont(fonts.board)
        love.graphics.printf(value, cell_x, cell_y + math.floor((cell - fonts.board:getHeight()) * 0.5) - 6, cell, "center")
      end
    end
  end
end

local function draw_session(width, height, metrics)
  local x = metrics.margin
  local y = metrics.topbar_h + metrics.gap
  local w = width - metrics.margin * 2
  local h = height - y - metrics.margin

  draw_panel(x, y, w, h, metrics.radius, palette.panel)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("Match", x + 18, y + 16)

  register_button(x + w - 200, y + 14, 88, 34, "Reset", request_reset, "accent")
  register_button(x + w - 104, y + 14, 88, 34, "Leave", leave_session, "danger")

  love.graphics.setFont(fonts.body)
  love.graphics.setColor(palette.text)
  love.graphics.printf(game.status, x + 18, y + 52, w - 36)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf("Your role: " .. symbol_name(game.role), x + 18, y + 80, w - 36)
  love.graphics.printf(player_line("X"), x + 18, y + 98, w - 36)
  love.graphics.printf(player_line("O"), x + 18, y + 114, w - 36)

  local board_size = math.min(w - 36, h - 250)
  board_size = clamp(board_size, 220, 360)
  local board_x = x + math.floor((w - board_size) * 0.5)
  local board_y = y + 142
  draw_board(board_x, board_y, board_size)

  local footer_y = board_y + board_size + 16
  local footer_h = h - (footer_y - y) - 16
  draw_panel(x + 18, footer_y, w - 36, footer_h, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Session", x + 32, footer_y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  local info_lines = network.session_info_lines()
  for i = 1, #info_lines do
    love.graphics.printf(info_lines[i], x + 32, footer_y + 42 + (i - 1) * 16, w - 64)
  end
end

local function pointer_pressed(x, y)
  debug_log(string.format("pointer %.1f, %.1f", x, y))
  for i = 1, #buttons do
    local btn = buttons[i]
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      debug_log("button hit: " .. btn.label)
      btn.action()
      return true
    end
  end

  return false
end

local function handle_game_event(ev)
  if ev.type == "hosted" then
    reset_local_game("Hosting match...")
    sync_host_players()

  elseif ev.type == "joined" then
    reset_local_game("Joined match. Waiting for board state...")

  elseif ev.type == "peer_joined" or ev.type == "peer_left" or ev.type == "session_resumed" then
    if app.is_host then
      sync_host_players()
    end

  elseif ev.type == "session_ended" then
    reset_local_game("Session ended.")

  elseif ev.type == "message" then
    if ev.msg_type == "ttt_state" then
      apply_state(ev.payload)
    elseif ev.msg_type == "ttt_move" and app.is_host then
      local index = tonumber(ev.payload and ev.payload.index)
      if not index then
        network.push_notice("Invalid move payload")
        return
      end
      host_apply_move(ev.peer_id, index)
    elseif ev.msg_type == "ttt_reset" and app.is_host then
      host_reset()
    end
  end
end

function love.load()
  fonts.title = love.graphics.newFont(22)
  fonts.section = love.graphics.newFont(18)
  fonts.subsection = love.graphics.newFont(15)
  fonts.body = love.graphics.newFont(13)
  fonts.small = love.graphics.newFont(11)
  fonts.board = love.graphics.newFont(42)

  network.set_event_handler(handle_game_event)
  network.initialize()
  reset_local_game("Host or join a room to begin.")
end

function love.update()
  network.update()
end

function love.draw()
  buttons = {}

  local width, height = love.graphics.getDimensions()
  local metrics = layout_metrics(width, height)

  love.graphics.clear(palette.bg)
  ui.diagnostics_view = nil

  if ui.diagnostics_open then
    draw_diagnostics_overlay(width, height, metrics)
  else
    draw_topbar(width, metrics)

    if app.in_session then
      draw_session(width, height, metrics)
    else
      draw_menu(width, height, metrics)
    end

    local corner_inset = 8
    register_button(width - corner_inset - 64, corner_inset, 64, 28, "Logs", function()
      ui.diagnostics_open = true
      ui.diagnostics_scroll = 0
      ui.diagnostics_dragging = false
    end, "ghost")
  end

  for i = 1, #buttons do
    draw_button(buttons[i])
  end
end

function love.mousepressed(x, y, button)
  if button ~= 1 then
    return
  end

  pointer_pressed(x, y)

  if ui.diagnostics_open and ui.diagnostics_view then
    local view = ui.diagnostics_view
    if x >= view.x and x <= view.x + view.w and y >= view.y and y <= view.y + view.h then
      ui.diagnostics_dragging = true
      ui.diagnostics_drag_last_y = y
    end
  end
end

function love.touchpressed(_, x, y)
  pointer_pressed(x, y)

  if ui.diagnostics_open and ui.diagnostics_view then
    local view = ui.diagnostics_view
    if x >= view.x and x <= view.x + view.w and y >= view.y and y <= view.y + view.h then
      ui.diagnostics_dragging = true
      ui.diagnostics_drag_last_y = y
    end
  end
end

function love.mousereleased(_, _, button)
  if button == 1 then
    ui.diagnostics_dragging = false
  end
end

function love.touchreleased()
  ui.diagnostics_dragging = false
end

function love.mousemoved(_, y)
  if ui.diagnostics_open and ui.diagnostics_dragging and ui.diagnostics_view then
    local dy = y - ui.diagnostics_drag_last_y
    local lines = math.floor(dy / ui.diagnostics_view.line_h)
    if lines ~= 0 then
      adjust_diagnostics_scroll(-lines)
      ui.diagnostics_drag_last_y = y
    end
  end
end

function love.touchmoved(_, x, y)
  if ui.diagnostics_open and ui.diagnostics_dragging and ui.diagnostics_view then
    local view = ui.diagnostics_view
    if x >= view.x and x <= view.x + view.w then
      local dy = y - ui.diagnostics_drag_last_y
      local lines = math.floor(dy / view.line_h)
      if lines ~= 0 then
        adjust_diagnostics_scroll(-lines)
        ui.diagnostics_drag_last_y = y
      end
    end
  end
end

function love.wheelmoved(_, y)
  if ui.diagnostics_open and ui.diagnostics_view then
    adjust_diagnostics_scroll(-y * 3)
  end
end

function love.keypressed(key)
  if ui.diagnostics_open and (key == "escape" or key == "back") then
    ui.diagnostics_open = false
    ui.diagnostics_dragging = false
    return
  end

  if key == "back" or key == "escape" then
    if app.in_session then
      leave_session()
    end
  end
end
