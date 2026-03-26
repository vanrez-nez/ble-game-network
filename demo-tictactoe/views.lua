local ble_ui = require("ble_ui")
local palette = ble_ui.palette
local buttons = ble_ui.buttons

local M = {}

M.board_colors = {
  symbol_x = {0.95, 0.35, 0.35},
  symbol_o = {0.30, 0.85, 0.50},
  grid_line = {0.30, 0.34, 0.42},
  info_label = {0.78, 0.82, 0.88},
  info_value = {0.55, 0.60, 0.68},
}

local game, app, fonts, network
local play_cell_fn, request_reset_fn, leave_session_fn

function M.init(deps)
  game = deps.game
  app = deps.app
  fonts = deps.fonts
  network = deps.network
  play_cell_fn = deps.play_cell
  request_reset_fn = deps.request_reset
  leave_session_fn = deps.leave_session
end

function M.draw_board(x, y, size)
  local bc = M.board_colors
  local gap = 8
  local cell = math.floor((size - gap * 2) / 3)
  local start_x = x + math.floor((size - (cell * 3 + gap * 2)) * 0.5)
  local start_y = y + math.floor((size - (cell * 3 + gap * 2)) * 0.5)

  love.graphics.setColor(bc.grid_line)
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

      buttons.register(cx, cy, cell, cell, "", function() play_cell_fn(index) end, "invisible")

      if value ~= "" then
        love.graphics.setColor(value == "X" and bc.symbol_x or bc.symbol_o)
        love.graphics.setFont(fonts.board)
        love.graphics.printf(value, cx, cy + math.floor((cell - fonts.board:getHeight()) * 0.5), cell, "center")
      end
    end
  end
end

function M.draw_endgame(x, y, w, h)
  local e = require("game").endgame
  if not e.active then return end
  local t = e.timer
  local fade = math.min(t / 0.5, 1.0)
  local scale = 1.0 + 0.5 * math.max(0, 1.0 - t / 0.6)
  if t > 0.6 then scale = scale + 0.03 * math.sin((t - 0.6) * 3) end

  love.graphics.setColor(0, 0, 0, 0.55 * fade)
  love.graphics.rectangle("fill", x, y, w, h)

  local bc = M.board_colors
  local r, g, b = 0.95, 0.96, 0.98
  if e.text == "You win!" then
    local c = game.role == "X" and bc.symbol_x or bc.symbol_o
    r, g, b = c[1], c[2], c[3]
  elseif e.text == "You lose!" then
    r, g, b = 0.70, 0.45, 0.45
  end

  love.graphics.setColor(r, g, b, fade)
  love.graphics.setFont(fonts.title)
  love.graphics.push()
  love.graphics.translate(x + w * 0.5, y + h * 0.4)
  love.graphics.scale(scale, scale)
  love.graphics.printf(e.text, -w * 0.5, -fonts.title:getHeight() * 0.5, w, "center")
  love.graphics.pop()

  if t > 1.5 then
    local tap_alpha = 0.5 + 0.5 * math.sin(t * 3)
    love.graphics.setColor(0.95, 0.96, 0.98, tap_alpha * fade)
    love.graphics.setFont(fonts.small)
    love.graphics.printf("Tap to continue", x, y + h * 0.55, w, "center")
  end
end

function M.draw_session(width, height, metrics)
  local display_name = require("game").display_name
  local bc = M.board_colors
  local x = metrics.margin
  local y = metrics.topbar_h + metrics.gap
  local w = width - metrics.margin * 2
  local h = height - y - metrics.margin

  local heading_h = 44
  love.graphics.setColor(bc.info_label)
  love.graphics.setFont(fonts.section)
  local title_y = y + math.floor((heading_h - fonts.section:getHeight()) * 0.5)
  love.graphics.print("Match", x + 4, title_y)

  local btn_h = 32
  local btn_y = y + math.floor((heading_h - btn_h) * 0.5)
  if app.is_host then
    buttons.register(x + w - 200, btn_y, 88, btn_h, "Restart", request_reset_fn, "accent")
  end
  buttons.register(x + w - 104, btn_y, 88, btn_h, "Leave", leave_session_fn, "danger")

  local turn_y = y + heading_h + 4
  love.graphics.setFont(fonts.body)
  if game.winner then
    love.graphics.setColor(bc.info_label)
    love.graphics.printf(game.status, x, turn_y, w, "center")
  elseif game.role == game.turn and game.players.X and game.players.O then
    local alpha = 0.5 + 0.5 * math.sin(love.timer.getTime() * 4)
    love.graphics.setColor(palette.accent[1], palette.accent[2], palette.accent[3], alpha)
    love.graphics.printf("Your turn!", x, turn_y, w, "center")
  elseif game.role == "viewer" then
    love.graphics.setColor(bc.info_value)
    love.graphics.printf(game.status, x, turn_y, w, "center")
  elseif game.players.X and game.players.O then
    love.graphics.setColor(bc.info_value)
    love.graphics.printf("Waiting for opponent...", x, turn_y, w, "center")
  else
    love.graphics.setColor(bc.info_value)
    love.graphics.printf(game.status, x, turn_y, w, "center")
  end

  local content_top = turn_y + fonts.body:getHeight() + 12
  local available_h = y + h - content_top
  local board_size = math.min(w - 16, available_h - 16)
  board_size = ble_ui.clamp(board_size, 180, 400)
  local board_x = x + math.floor((w - board_size) * 0.5)
  local board_y = content_top + math.floor((available_h - board_size) * 0.5)
  M.draw_board(board_x, board_y, board_size)

  love.graphics.setFont(fonts.small)
  local label_y = board_y + board_size + 8
  local x_label = "X " .. display_name(game.players.X)
  local o_label = "O " .. display_name(game.players.O)
  local sep = "     "
  local full = x_label .. sep .. o_label
  local full_w = fonts.small:getWidth(full)
  local start_tx = x + math.floor((w - full_w) * 0.5)
  love.graphics.setColor(bc.symbol_x)
  love.graphics.print(x_label, start_tx, label_y)
  love.graphics.setColor(bc.symbol_o)
  love.graphics.print(o_label, start_tx + fonts.small:getWidth(x_label .. sep), label_y)

  M.draw_endgame(x, y, w, h)
end

function M.draw_name_screen(width, height, metrics, player_name, input_active, confirm_fn)
  local x = metrics.margin
  local w = width - metrics.margin * 2
  local center_y = math.floor(height * 0.35)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.title)
  love.graphics.printf("BLE Tic-Tac-Toe", x, center_y, w, "center")

  love.graphics.setColor(palette.dim)
  love.graphics.setFont(fonts.body)
  love.graphics.printf("Choose your name", x, center_y + 36, w, "center")

  local input_h = 48
  local input_w = math.min(w - 32, 300)
  local input_x = math.floor((width - input_w) * 0.5)
  local input_y = center_y + 72

  love.graphics.setColor(0.12, 0.14, 0.18)
  love.graphics.rectangle("fill", input_x, input_y, input_w, input_h, 14, 14)
  love.graphics.setColor(input_active and palette.accent or palette.stroke)
  love.graphics.rectangle("line", input_x, input_y, input_w, input_h, 14, 14)

  love.graphics.setFont(fonts.section)
  love.graphics.setColor(palette.text)
  love.graphics.printf(player_name, input_x + 16, input_y + math.floor((input_h - fonts.section:getHeight()) * 0.5), input_w - 32, "center")

  local btn_w = math.min(input_w, 200)
  local btn_h = 48
  local btn_x = math.floor((width - btn_w) * 0.5)
  local btn_y = input_y + input_h + 20
  buttons.register(btn_x, btn_y, btn_w, btn_h, "Play", confirm_fn, "accent")

  love.graphics.setColor(palette.dim)
  love.graphics.setFont(fonts.small)
  love.graphics.printf("Tap the name to edit, or just hit Play", x, btn_y + btn_h + 16, w, "center")

  return { x = input_x, y = input_y, w = input_w, h = input_h }
end

local function dump(v, depth)
  depth = depth or 0
  if depth > 2 then return "..." end
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, val in pairs(v) do
    parts[#parts + 1] = tostring(k) .. "=" .. dump(val, depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.make_debug_content(network_ref)
  return function(cx, cy, cw, ch, f)
    love.graphics.setFont(f.small)
    local lh = f.small:getHeight() + 3
    local now = love.timer.getTime()

    local function heading(text)
      love.graphics.setColor(0.55, 0.70, 0.45)
      love.graphics.print(text, cx, cy)
      cy = cy + lh
    end

    local function line(text)
      love.graphics.setColor(0.80, 0.85, 0.65)
      love.graphics.printf(text, cx + 4, cy, cw - 8)
      local _, wrapped = f.small:getWrap(text, cw - 8)
      cy = cy + math.max(1, #wrapped) * f.small:getHeight() + 2
    end

    heading("LAST RECEIVED")
    local i = network_ref.last_in
    if i then
      line(string.format("%s from %s  (%.1fs ago)", i.msg_type or "?", i.peer_id or "?", now - i.time))
      if i.payload then line(dump(i.payload)) end
    else
      line("(none)")
    end

    cy = cy + 6
    heading("LAST SENT")
    local o = network_ref.last_out
    if o then
      line(string.format("%s  (%.1fs ago)", o.msg_type or "?", now - o.time))
      if o.payload then line(dump(o.payload)) end
    else
      line("(none)")
    end
  end
end

return M
