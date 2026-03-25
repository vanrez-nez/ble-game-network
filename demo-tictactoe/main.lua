local utf8 = require("utf8")
local ble_net = require("ble_net")
local ble_ui = require("ble_ui")

local network = ble_net.new({
  title = "BLE Tic-Tac-Toe",
  room_name = "Tic-Tac-Toe",
  max_clients = 6,
  debug_prefix = "[demo-tictactoe]",
})

local palette = ble_ui.palette
local diag = ble_ui.diagnostics
local app = network.state

local game = {
  board = {"", "", "", "", "", "", "", "", ""},
  turn = "X",
  winner = nil,
  players = { X = nil, O = nil },
  names = {},
  role = "viewer",
  status = "Host or join a room to begin.",
}

local endgame_anim = {
  active = false,
  timer = 0,
  text = "",
  dismissed = false,
}

local local_player_name = ""
local name_input_active = false
local name_input_box = nil

local buttons = {}
local fonts = {}
local debug_enabled = true

local winning_lines = {
  {1, 2, 3}, {4, 5, 6}, {7, 8, 9},
  {1, 4, 7}, {2, 5, 8}, {3, 6, 9},
  {1, 5, 9}, {3, 5, 7},
}

local board_colors = {
  cell_empty = {0.19, 0.22, 0.28},
  symbol_x = {1.00, 0.78, 0.42},
  symbol_o = {0.46, 0.94, 0.68},
  grid_line = {0.30, 0.34, 0.42},
  info_label = {0.78, 0.82, 0.88},
  info_value = {0.55, 0.60, 0.68},
}

local function debug_log(text)
  if debug_enabled then
    print("[demo-tictactoe] " .. text)
  end
end

local function display_name(peer_id)
  if not peer_id then return "waiting" end
  if game.names[peer_id] and game.names[peer_id] ~= "" then
    return game.names[peer_id]
  end
  return "Player"
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
  game.names = {}
  game.role = "viewer"
  game.status = status or "Waiting for host state..."
  app.status = game.status
  endgame_anim.active = false
  endgame_anim.timer = 0
  endgame_anim.dismissed = false
  endgame_anim.text = ""
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

local function check_endgame_trigger()
  if game.winner and not endgame_anim.active and not endgame_anim.dismissed then
    endgame_anim.active = true
    endgame_anim.timer = 0
    if game.winner == "draw" then
      endgame_anim.text = "Draw!"
    elseif game.winner == game.role then
      endgame_anim.text = "You win!"
    elseif game.role == "viewer" then
      endgame_anim.text = symbol_name(game.winner) .. " wins!"
    else
      endgame_anim.text = "You lose!"
    end
  end
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
  if not game.players.X and not game.players.O then
    return "Waiting for players..."
  end
  if not game.players.X then
    return "Waiting for Player X..."
  end
  if not game.players.O then
    return "Waiting for Player O..."
  end
  if game.winner == "draw" then
    return "Draw game."
  end
  if game.winner == "X" or game.winner == "O" then
    return display_name(game.players[game.winner]) .. " wins!"
  end
  if not game.players[game.turn] then
    return "Waiting for replacement..."
  end
  return display_name(game.players[game.turn]) .. " to move."
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
    if board[i] == "" then return nil end
  end
  return "draw"
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
    names = game.names,
  })
  check_endgame_trigger()
end

local function host_reset()
  game.board = {"", "", "", "", "", "", "", "", ""}
  game.turn = "X"
  game.winner = nil
  endgame_anim.active = false
  endgame_anim.timer = 0
  endgame_anim.dismissed = false
  endgame_anim.text = ""
  broadcast_state()
end

local function sync_host_players()
  if not app.is_host then return end

  local remotes = remote_peers()
  local present = {}
  local assigned = {}
  local candidates = {}

  if app.local_id ~= "" then present[app.local_id] = true end
  for i = 1, #remotes do present[remotes[i]] = true end

  if game.players.X and not present[game.players.X] then game.players.X = nil end
  if game.players.O and not present[game.players.O] then game.players.O = nil end
  if game.players.X and game.players.O and game.players.X == game.players.O then game.players.O = nil end

  if game.players.X then assigned[game.players.X] = true end
  if game.players.O then assigned[game.players.O] = true end

  if app.local_id ~= "" and not assigned[app.local_id] then
    candidates[#candidates + 1] = app.local_id
    assigned[app.local_id] = true
  end
  for i = 1, #remotes do
    local peer_id = remotes[i]
    if not assigned[peer_id] then
      candidates[#candidates + 1] = peer_id
      assigned[peer_id] = true
    end
  end

  if not game.players.X and #candidates > 0 then game.players.X = table.remove(candidates, 1) end
  if not game.players.O and #candidates > 0 then game.players.O = table.remove(candidates, 1) end

  broadcast_state()
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
  if type(payload.names) == "table" then
    game.names = payload.names
  end
  game.status = tostring(payload.status or describe_board_state())
  app.status = game.status
  update_local_role()
  check_endgame_trigger()
end

local function host_apply_move(actor_id, index)
  if not app.is_host then return end
  if type(index) ~= "number" or index < 1 or index > 9 then return end
  if not game.players.O then network.push_notice("Waiting for a second player"); return end
  if game.winner then network.push_notice("Round is over. Restart to play again."); return end

  local expected_peer = game.players[game.turn]
  if actor_id ~= expected_peer then network.push_notice("It is not your turn"); return end
  if game.board[index] ~= "" then network.push_notice("That square is already taken"); return end

  game.board[index] = game.turn
  game.winner = check_winner(game.board)
  if not game.winner then
    game.turn = game.turn == "X" and "O" or "X"
  end
  broadcast_state()
end

local function request_reset()
  if not app.is_host then return end
  host_reset()
end

local function play_cell(index)
  if not app.in_session then return end
  if game.role == "viewer" then network.push_notice("Viewers cannot play"); return end
  if game.role ~= game.turn then network.push_notice("Wait for your turn"); return end

  if app.is_host then
    host_apply_move(app.local_id, index)
  else
    network.broadcast_payload("ttt_move", { index = index })
  end
end

local function set_player_name(name)
  local trimmed = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" or #trimmed > 24 then return end
  local_player_name = trimmed
  name_input_active = false
  love.keyboard.setTextInput(false)
  if app.is_host then
    game.names[app.local_id] = trimmed
    broadcast_state()
  else
    network.broadcast_payload("ttt_name", { name = trimmed })
  end
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
  name_input_active = false
  love.keyboard.setTextInput(false)
  network.leave_session()
end

local function draw_board(x, y, size)
  local gap = 8
  local cell = math.floor((size - gap * 2) / 3)
  local start_x = x + math.floor((size - (cell * 3 + gap * 2)) * 0.5)
  local start_y = y + math.floor((size - (cell * 3 + gap * 2)) * 0.5)

  love.graphics.setColor(board_colors.grid_line)
  local grid_r = 6
  love.graphics.rectangle("fill", start_x + cell, start_y, gap, cell * 3 + gap * 2, grid_r, grid_r)
  love.graphics.rectangle("fill", start_x + cell * 2 + gap, start_y, gap, cell * 3 + gap * 2, grid_r, grid_r)
  love.graphics.rectangle("fill", start_x, start_y + cell, cell * 3 + gap * 2, gap, grid_r, grid_r)
  love.graphics.rectangle("fill", start_x, start_y + cell * 2 + gap, cell * 3 + gap * 2, gap, grid_r, grid_r)

  for row = 0, 2 do
    for col = 0, 2 do
      local index = row * 3 + col + 1
      local cx = start_x + col * (cell + gap)
      local cy = start_y + row * (cell + gap)
      local value = game.board[index]

      love.graphics.setColor(board_colors.cell_empty)
      love.graphics.rectangle("fill", cx, cy, cell, cell, 14, 14)

      ble_ui.draw.register_button(buttons, cx, cy, cell, cell, "", function()
        play_cell(index)
      end, "ghost")

      if value ~= "" then
        love.graphics.setColor(value == "X" and board_colors.symbol_x or board_colors.symbol_o)
        love.graphics.setFont(fonts.board)
        love.graphics.printf(value, cx, cy + math.floor((cell - fonts.board:getHeight()) * 0.5), cell, "center")
      end
    end
  end
end

local function draw_endgame_overlay(x, y, w, h)
  if not endgame_anim.active then return end

  local t = endgame_anim.timer
  local fade = math.min(t / 0.5, 1.0)
  local scale = 1.0 + 0.5 * math.max(0, 1.0 - t / 0.6)
  if t > 0.6 then
    scale = scale + 0.03 * math.sin((t - 0.6) * 3)
  end

  love.graphics.setColor(0, 0, 0, 0.55 * fade)
  love.graphics.rectangle("fill", x, y, w, h)

  local r, g, b = 0.95, 0.96, 0.98
  if endgame_anim.text == "You win!" then
    r, g, b = board_colors.symbol_x[1], board_colors.symbol_x[2], board_colors.symbol_x[3]
  elseif endgame_anim.text == "You lose!" then
    r, g, b = palette.danger[1], palette.danger[2], palette.danger[3]
  end

  love.graphics.setColor(r, g, b, fade)
  love.graphics.setFont(fonts.title)

  love.graphics.push()
  local cx = x + w * 0.5
  local cy = y + h * 0.4
  love.graphics.translate(cx, cy)
  love.graphics.scale(scale, scale)
  love.graphics.printf(endgame_anim.text, -w * 0.5, -fonts.title:getHeight() * 0.5, w, "center")
  love.graphics.pop()

  if t > 1.5 then
    local tap_alpha = 0.5 + 0.5 * math.sin(t * 3)
    love.graphics.setColor(0.95, 0.96, 0.98, tap_alpha * fade)
    love.graphics.setFont(fonts.small)
    love.graphics.printf("Tap to continue", x, y + h * 0.55, w, "center")
  end
end

local function draw_session(width, height, metrics)
  local x = metrics.margin
  local y = metrics.topbar_h + metrics.gap
  local w = width - metrics.margin * 2
  local h = height - y - metrics.margin

  local heading_h = 44
  love.graphics.setColor(board_colors.info_label)
  love.graphics.setFont(fonts.section)
  local title_y = y + math.floor((heading_h - fonts.section:getHeight()) * 0.5)
  love.graphics.print("Match", x + 4, title_y)

  local btn_h = 32
  local btn_y = y + math.floor((heading_h - btn_h) * 0.5)
  if app.is_host then
    ble_ui.draw.register_button(buttons, x + w - 200, btn_y, 88, btn_h, "Restart", request_reset, "accent")
  end
  ble_ui.draw.register_button(buttons, x + w - 104, btn_y, 88, btn_h, "Leave", leave_session, "danger")

  local turn_y = y + heading_h + 4
  love.graphics.setFont(fonts.body)
  if game.winner then
    love.graphics.setColor(board_colors.info_label)
    love.graphics.printf(game.status, x, turn_y, w, "center")
  elseif game.role == game.turn and game.players.X and game.players.O then
    local alpha = 0.5 + 0.5 * math.sin(love.timer.getTime() * 4)
    love.graphics.setColor(palette.accent[1], palette.accent[2], palette.accent[3], alpha)
    love.graphics.printf("Your turn!", x, turn_y, w, "center")
  elseif game.players.X and game.players.O then
    love.graphics.setColor(board_colors.info_value)
    love.graphics.printf("Waiting for opponent...", x, turn_y, w, "center")
  else
    love.graphics.setColor(board_colors.info_value)
    love.graphics.printf(game.status, x, turn_y, w, "center")
  end

  local name_area_h = 0
  if local_player_name == "" and app.in_session then
    name_area_h = 56
  end

  local content_top = turn_y + fonts.body:getHeight() + 12
  local content_bottom = y + h - name_area_h
  local available_h = content_bottom - content_top

  local board_size = math.min(w - 16, available_h - 16)
  board_size = ble_ui.clamp(board_size, 180, 400)
  local board_x = x + math.floor((w - board_size) * 0.5)
  local board_y = content_top + math.floor((available_h - board_size) * 0.5)
  draw_board(board_x, board_y, board_size)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(board_colors.info_value)
  local x_name = "X: " .. display_name(game.players.X)
  local o_name = "O: " .. display_name(game.players.O)
  love.graphics.printf(x_name .. "     " .. o_name, x, board_y + board_size + 8, w, "center")

  if local_player_name == "" and app.in_session then
    local input_h = 40
    local input_y = y + h - input_h - 4
    local set_w = 64
    local input_x = x + 4
    local input_w = w - set_w - 16

    love.graphics.setColor(0.12, 0.14, 0.18)
    love.graphics.rectangle("fill", input_x, input_y, input_w, input_h, 12, 12)
    love.graphics.setColor(palette.stroke)
    love.graphics.rectangle("line", input_x, input_y, input_w, input_h, 12, 12)

    love.graphics.setFont(fonts.body)
    love.graphics.setColor(name_input_active and palette.text or palette.dim)
    local display = local_player_name == "" and "Your name..." or local_player_name
    love.graphics.printf(display, input_x + 12, input_y + math.floor((input_h - fonts.body:getHeight()) * 0.5), input_w - 24)

    name_input_box = { x = input_x, y = input_y, w = input_w, h = input_h }

    ble_ui.draw.register_button(buttons, input_x + input_w + 8, input_y, set_w, input_h, "Set", function()
      set_player_name(local_player_name)
    end, "accent")
  else
    name_input_box = nil
  end

  draw_endgame_overlay(x, y, w, h)
end

local function pointer_pressed(px, py)
  debug_log(string.format("pointer %.1f, %.1f", px, py))

  if endgame_anim.active and endgame_anim.timer > 1.0 then
    endgame_anim.active = false
    endgame_anim.dismissed = true
    return true
  end

  local btn = ble_ui.draw.pointer_pressed(buttons, px, py)
  if btn then
    debug_log("button hit: " .. btn.label)
    return true
  end

  if name_input_box then
    local box = name_input_box
    local inside = px >= box.x and px <= box.x + box.w and py >= box.y and py <= box.y + box.h
    if inside then
      name_input_active = true
      love.keyboard.setTextInput(true, box.x, box.y, box.w, box.h)
      return true
    else
      name_input_active = false
      love.keyboard.setTextInput(false)
    end
  end

  return false
end

local function handle_game_event(ev)
  if ev.type == "hosted" then
    reset_local_game("Hosting match...")
    if local_player_name ~= "" then
      game.names[app.local_id] = local_player_name
    end
    sync_host_players()

  elseif ev.type == "joined" then
    reset_local_game("Joined match. Waiting for board state...")
    if local_player_name ~= "" then
      network.broadcast_payload("ttt_name", { name = local_player_name })
    end

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
    elseif ev.msg_type == "ttt_name" and app.is_host then
      local name = ev.payload and ev.payload.name
      if type(name) == "string" and #name > 0 and #name <= 24 then
        game.names[ev.peer_id] = name
        broadcast_state()
      end
    elseif ev.msg_type == "ttt_reset" then
      debug_log("ignoring ttt_reset from " .. tostring(ev.peer_id))
    end
  end
end

function love.load()
  love.keyboard.setKeyRepeat(true)
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

function love.update(dt)
  network.update()
  if endgame_anim.active then
    endgame_anim.timer = endgame_anim.timer + dt
  end
end

function love.draw()
  buttons = {}
  name_input_box = nil

  local width, height = love.graphics.getDimensions()
  local metrics = ble_ui.layout_metrics(width, height)

  love.graphics.clear(palette.bg)

  ble_ui.draw_frame({
    width = width,
    height = height,
    metrics = metrics,
    buttons = buttons,
    fonts = fonts,
    app = app,
    network = network,
    lobby_description = "Host a room for a two-player tic-tac-toe match. Extra peers join as viewers and watch the board state live.",
    start_host = start_host,
    start_scan = start_scan,
    transport = ble_net.TRANSPORT,
    draw_session = function()
      draw_session(width, height, metrics)
    end,
  })
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  pointer_pressed(x, y)
  diag.on_pressed(x, y)
end

function love.touchpressed(_, x, y)
  pointer_pressed(x, y)
  diag.on_pressed(x, y)
end

function love.mousereleased(_, _, button)
  if button == 1 then diag.on_released() end
end

function love.touchreleased()
  diag.on_released()
end

function love.mousemoved(_, y)
  diag.on_moved(0, y)
end

function love.touchmoved(_, x, y)
  diag.on_touch_moved(x, y)
end

function love.wheelmoved(_, y)
  diag.on_wheel(y)
end

function love.textinput(text)
  if name_input_active then
    local_player_name = local_player_name .. text
  end
end

function love.keypressed(key)
  if diag.is_open() and (key == "escape" or key == "back") then
    diag.close()
    return
  end

  if name_input_active then
    if key == "backspace" then
      local byteoffset = utf8.offset(local_player_name, -1)
      if byteoffset then
        local_player_name = string.sub(local_player_name, 1, byteoffset - 1)
      end
    elseif key == "return" or key == "kpenter" then
      set_player_name(local_player_name)
    elseif key == "escape" then
      name_input_active = false
      love.keyboard.setTextInput(false)
    end
    return
  end

  if key == "back" or key == "escape" then
    if app.in_session then
      leave_session()
    end
  end
end
