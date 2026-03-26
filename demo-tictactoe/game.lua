local M = {}

local winning_lines = {
  {1, 2, 3}, {4, 5, 6}, {7, 8, 9},
  {1, 4, 7}, {2, 5, 8}, {3, 6, 9},
  {1, 5, 9}, {3, 5, 7},
}

M.state = {
  board = {"", "", "", "", "", "", "", "", ""},
  turn = "X",
  winner = nil,
  players = { X = nil, O = nil },
  names = {},
  role = "viewer",
  status = "Host or join a room to begin.",
}

M.endgame = {
  active = false,
  timer = 0,
  text = "",
  dismissed = false,
}

local network, app

function M.init(net, app_state)
  network = net
  app = app_state
end

function M.display_name(peer_id)
  if not peer_id then return "waiting" end
  if M.state.names[peer_id] and M.state.names[peer_id] ~= "" then
    return M.state.names[peer_id]
  end
  return "Player"
end

local function board_copy(source)
  local copy = {}
  for i = 1, 9 do copy[i] = source[i] or "" end
  return copy
end

function M.symbol_name(symbol)
  if symbol == "X" then return "Player X"
  elseif symbol == "O" then return "Player O"
  elseif symbol == "draw" then return "Draw"
  end
  return "Viewer"
end

local function check_endgame_trigger()
  local g = M.state
  local e = M.endgame
  if g.winner and not e.active and not e.dismissed then
    e.active = true
    e.timer = 0
    if g.winner == "draw" then e.text = "Draw!"
    elseif g.winner == g.role then e.text = "You win!"
    elseif g.role == "viewer" then e.text = M.symbol_name(g.winner) .. " wins!"
    else e.text = "You lose!" end
  end
end

local function update_local_role()
  local g = M.state
  local previous = g.role
  if app.local_id ~= "" and app.local_id == g.players.X then g.role = "X"
  elseif app.local_id ~= "" and app.local_id == g.players.O then g.role = "O"
  else g.role = "viewer" end
  if previous ~= g.role and app.in_session then
    if g.role == "viewer" then network.push_notice("You are watching this round")
    else network.push_notice("You are " .. g.role) end
  end
end

local function describe_board_state()
  local g = M.state
  if not g.players.X and not g.players.O then return "Waiting for players..." end
  if not g.players.X then return "Waiting for Player X..." end
  if not g.players.O then return "Waiting for Player O..." end
  if g.winner == "draw" then return "Draw game." end
  if g.winner == "X" or g.winner == "O" then return M.display_name(g.players[g.winner]) .. " wins!" end
  if not g.players[g.turn] then return "Waiting for replacement..." end
  return M.display_name(g.players[g.turn]) .. " to move."
end

local function check_winner(board)
  for i = 1, #winning_lines do
    local line = winning_lines[i]
    local first = board[line[1]]
    if first ~= "" and first == board[line[2]] and first == board[line[3]] then return first end
  end
  for i = 1, 9 do if board[i] == "" then return nil end end
  return "draw"
end

local function remote_peers()
  local peers = {}
  for i = 1, #app.peers do
    if not app.peers[i].is_host then peers[#peers + 1] = app.peers[i].peer_id end
  end
  table.sort(peers)
  return peers
end

function M.broadcast_state()
  local g = M.state
  g.status = describe_board_state()
  app.status = g.status
  update_local_role()
  network.broadcast_payload("ttt_state", {
    board = board_copy(g.board),
    turn = g.turn,
    winner = g.winner or "",
    status = g.status,
    players = { X = g.players.X or "", O = g.players.O or "" },
    names = g.names,
  })
  check_endgame_trigger()
end

function M.sync_host_players()
  if not app.is_host then return end
  local g = M.state
  local remotes = remote_peers()
  local present, assigned, candidates = {}, {}, {}
  if app.local_id ~= "" then present[app.local_id] = true end
  for i = 1, #remotes do present[remotes[i]] = true end
  if g.players.X and not present[g.players.X] then g.players.X = nil end
  if g.players.O and not present[g.players.O] then g.players.O = nil end
  if g.players.X and g.players.O and g.players.X == g.players.O then g.players.O = nil end
  if g.players.X then assigned[g.players.X] = true end
  if g.players.O then assigned[g.players.O] = true end
  if app.local_id ~= "" and not assigned[app.local_id] then
    candidates[#candidates + 1] = app.local_id; assigned[app.local_id] = true
  end
  for i = 1, #remotes do
    if not assigned[remotes[i]] then candidates[#candidates + 1] = remotes[i]; assigned[remotes[i]] = true end
  end
  if not g.players.X and #candidates > 0 then g.players.X = table.remove(candidates, 1) end
  if not g.players.O and #candidates > 0 then g.players.O = table.remove(candidates, 1) end
  M.broadcast_state()
end

function M.reset(status)
  local g = M.state
  local e = M.endgame
  g.board = {"", "", "", "", "", "", "", "", ""}
  g.turn = "X"
  g.winner = nil
  g.players.X = nil
  g.players.O = nil
  g.names = {}
  g.role = "viewer"
  g.status = status or "Waiting for host state..."
  app.status = g.status
  e.active = false; e.timer = 0; e.dismissed = false; e.text = ""
end

function M.host_reset()
  local e = M.endgame
  M.state.board = {"", "", "", "", "", "", "", "", ""}
  M.state.turn = "X"
  M.state.winner = nil
  e.active = false; e.timer = 0; e.dismissed = false; e.text = ""
  M.sync_host_players()
end

function M.apply_state(payload)
  if type(payload) ~= "table" or type(payload.board) ~= "table" or type(payload.players) ~= "table" then
    network.push_notice("Invalid tic-tac-toe state payload"); return
  end
  local next_board = {}
  for i = 1, 9 do
    local v = payload.board[i]
    if v ~= "" and v ~= "X" and v ~= "O" then network.push_notice("Invalid tic-tac-toe board value"); return end
    next_board[i] = v or ""
  end
  if payload.turn ~= "X" and payload.turn ~= "O" then network.push_notice("Invalid tic-tac-toe turn"); return end
  if payload.winner ~= "" and payload.winner ~= "X" and payload.winner ~= "O" and payload.winner ~= "draw" then
    network.push_notice("Invalid tic-tac-toe winner"); return
  end
  local g = M.state
  g.board = next_board
  g.turn = payload.turn
  g.winner = payload.winner ~= "" and payload.winner or nil
  g.players.X = payload.players.X ~= "" and payload.players.X or nil
  g.players.O = payload.players.O ~= "" and payload.players.O or nil
  if type(payload.names) == "table" then g.names = payload.names end
  g.status = tostring(payload.status or describe_board_state())
  app.status = g.status
  g._last_apply_time = love.timer.getTime()
  update_local_role()
  check_endgame_trigger()
end

function M.host_apply_move(actor_id, index)
  if not app.is_host then return end
  local g = M.state
  if type(index) ~= "number" or index < 1 or index > 9 then return end
  if not g.players.O then network.push_notice("Waiting for a second player"); return end
  if g.winner then network.push_notice("Round is over. Restart to play again."); return end
  if actor_id ~= g.players[g.turn] then network.push_notice("It is not your turn"); return end
  if g.board[index] ~= "" then network.push_notice("That square is already taken"); return end
  g.board[index] = g.turn
  g.winner = check_winner(g.board)
  if not g.winner then g.turn = g.turn == "X" and "O" or "X" end
  M.broadcast_state()
end

function M.play_cell(index)
  if not app.in_session then return end
  local g = M.state
  if g.role == "viewer" then network.push_notice("Viewers cannot play"); return end
  if g.role ~= g.turn then network.push_notice("Wait for your turn"); return end
  if app.is_host then
    M.host_apply_move(app.local_id, index)
  else
    network.broadcast_payload("ttt_move", { index = index })
  end
end

return M
