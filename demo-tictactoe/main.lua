local utf8 = require("utf8")
local ble_net = require("ble_net")
local ble_ui = require("ble_ui")
local game = require("game")
local views = require("views")
local diag = require("ble_diagnostics")

local network = ble_net.new({
  title = "BLE Tic-Tac-Toe",
  room_name = "Tic-Tac-Toe",
  max_clients = 6,
  debug_prefix = "[demo-tictactoe]",
})

local buttons = ble_ui.buttons
local palette = ble_ui.palette
local app = network.state

local aliases = {
  "Fox", "Owl", "Bear", "Wolf", "Lynx", "Hawk", "Crow", "Deer",
  "Orca", "Puma", "Hare", "Wren", "Pike", "Wasp", "Newt", "Toad",
  "Yak", "Ram", "Seal", "Ibis", "Lark", "Moth", "Crab", "Dove",
}

local local_player_name = ""
local name_confirmed = false
local name_input_active = false
local name_input_box = nil
local fonts = {}

local debug_overlay = ble_ui.overlay.new({ title = "Debug State" })

local function generate_alias()
  math.randomseed(os.time() + os.clock() * 1000)
  return aliases[math.random(#aliases)] .. tostring(math.random(10, 99))
end

local function confirm_name()
  local trimmed = (local_player_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then local_player_name = generate_alias(); trimmed = local_player_name end
  if #trimmed > 24 then trimmed = trimmed:sub(1, 24); local_player_name = trimmed end
  name_confirmed = true
  name_input_active = false
  love.keyboard.setTextInput(false)
end

local function send_name_to_session()
  if local_player_name == "" then return end
  if app.is_host then
    game.state.names[app.local_id] = local_player_name
    game.broadcast_state()
  else
    network.broadcast_payload("ttt_name", { name = local_player_name })
  end
end

local function request_reset()
  if not app.is_host then return end
  game.host_reset()
end

local function start_host(transport) game.reset("Starting host..."); network.start_host(transport) end
local function start_scan() game.reset("Scanning..."); network.start_scan() end
local function leave_session()
  game.reset("Returned to lobby.")
  name_input_active = false
  love.keyboard.setTextInput(false)
  network.leave_session()
end

local function handle_game_event(ev)
  if ev.type == "hosted" then
    game.reset("Hosting match...")
    send_name_to_session()
    game.sync_host_players()
  elseif ev.type == "joined" then
    game.reset("Joined match. Waiting for board state...")
    send_name_to_session()
  elseif ev.type == "peer_joined" or ev.type == "peer_left" or ev.type == "session_resumed" then
    if app.is_host then game.sync_host_players() end
  elseif ev.type == "session_ended" then
    game.reset("Session ended.")
  elseif ev.type == "message" then
    if ev.msg_type == "ttt_state" then
      game.apply_state(ev.payload)
    elseif ev.msg_type == "ttt_move" and app.is_host then
      local index = tonumber(ev.payload and ev.payload.index)
      if not index then network.push_notice("Invalid move payload"); return end
      game.host_apply_move(ev.peer_id, index)
    elseif ev.msg_type == "ttt_name" and app.is_host then
      local name = ev.payload and ev.payload.name
      if type(name) == "string" and #name > 0 and #name <= 24 then
        game.state.names[ev.peer_id] = name
        game.broadcast_state()
      end
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

  local_player_name = generate_alias()
  name_confirmed = false
  name_input_active = true

  game.init(network, app)
  views.init({
    game = game.state,
    app = app,
    fonts = fonts,
    network = network,
    play_cell = game.play_cell,
    request_reset = request_reset,
    leave_session = leave_session,
  })

  debug_overlay.content_fn = views.make_debug_content(network)

  network.set_event_handler(handle_game_event)
  network.initialize()
  game.reset("Host or join a room to begin.")
end

function love.update(dt)
  network.update()
  if game.endgame.active then
    game.endgame.timer = game.endgame.timer + dt
  end
end

function love.draw()
  name_input_box = nil
  local width, height = love.graphics.getDimensions()
  local metrics = ble_ui.layout_metrics(width, height)
  love.graphics.clear(palette.bg)

  if not name_confirmed then
    buttons.reset()
    name_input_box = views.draw_name_screen(width, height, metrics, local_player_name, name_input_active, confirm_name)
    buttons.render(fonts)
    return
  end

  diag.set_context(network, app)

  ble_ui.draw_frame({
    width = width,
    height = height,
    metrics = metrics,
    fonts = fonts,
    app = app,
    network = network,
    overlays = { diag.get_overlay(), debug_overlay },
    lobby_description = "Host a room for a two-player tic-tac-toe match. Extra peers join as viewers and watch the board state live.",
    start_host = start_host,
    start_scan = start_scan,
    transport = ble_net.TRANSPORT,
    draw_session = function()
      views.draw_session(width, height, metrics)
    end,
    extra_buttons = function()
      local btn_h = 28
      local btn_y = math.floor((metrics.topbar_h - btn_h) * 0.5)
      buttons.register(width - 8 - 64, btn_y, 64, btn_h, "Logs", function()
        diag.toggle()
      end, "ghost")
      buttons.register(width - 8 - 64 - 8 - 52, btn_y, 52, btn_h, "DBG", function()
        debug_overlay:toggle()
      end, "ghost")
    end,
  })
end

local touch_handled = false

local function handle_press(x, y)
  if game.endgame.active and game.endgame.timer > 1.0 then
    game.endgame.active = false
    game.endgame.dismissed = true
    return
  end

  local btn = buttons.pressed(x, y)
  if btn then return end

  if name_input_box then
    local box = name_input_box
    if x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h then
      name_input_active = true
      love.keyboard.setTextInput(true, box.x, box.y, box.w, box.h)
      return
    else
      name_input_active = false
      love.keyboard.setTextInput(false)
    end
  end

  diag.on_pressed(x, y)
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  if touch_handled then touch_handled = false; return end
  handle_press(x, y)
end

function love.touchpressed(_, x, y)
  touch_handled = true
  handle_press(x, y)
end

function love.mousereleased(x, y, button)
  if button == 1 then
    buttons.mousereleased(x, y)
    diag.on_released()
  end
end

function love.touchreleased(_, x, y)
  buttons.mousereleased(x or 0, y or 0)
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
  if diag.is_open() and (key == "escape" or key == "back") then diag.close(); return end

  if name_input_active then
    if key == "backspace" then
      local byteoffset = utf8.offset(local_player_name, -1)
      if byteoffset then local_player_name = string.sub(local_player_name, 1, byteoffset - 1) end
    elseif key == "return" or key == "kpenter" then
      if not name_confirmed then confirm_name() end
    elseif key == "escape" then
      name_input_active = false
      love.keyboard.setTextInput(false)
    end
    return
  end

  if key == "back" or key == "escape" then
    if app.in_session then leave_session() end
  end
end
