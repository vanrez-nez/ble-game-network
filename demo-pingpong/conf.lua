package.path = package.path .. ";../lua/?.lua;../lua/?/init.lua"

function love.conf(t)
  t.window.title = "BLE Ping Pong"
  t.window.width = 430
  t.window.height = 860
  t.window.fullscreen = true
  t.highdpi = true
  t.console = false
  t.modules.audio = false
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.sound = false
  t.modules.video = false
end
