local M = {}

local Cache = {}
Cache.__index = Cache

function Cache:new(opts)
  opts = opts or {}

  return setmetatable({
    max_age = tonumber(opts.max_age) or 0,
    max_count = math.max(1, math.floor(tonumber(opts.max_count) or 64)),
    entries = {},
    head = 1,
    lookup = {},
  }, self)
end

function Cache:_now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end

  return os.clock()
end

function Cache:_compact_if_needed()
  if self.head <= math.floor(#self.entries / 2) then
    return
  end

  local fresh = {}
  for i = self.head, #self.entries do
    fresh[#fresh + 1] = self.entries[i]
  end

  self.entries = fresh
  self.head = 1
end

function Cache:_cleanup(now)
  if self.max_age > 0 then
    local cutoff = now - self.max_age
    while self.head <= #self.entries do
      local entry = self.entries[self.head]
      if entry.timestamp >= cutoff then
        break
      end

      if self.lookup[entry.key] == entry.timestamp then
        self.lookup[entry.key] = nil
      end
      self.head = self.head + 1
    end
  end

  while (#self.entries - self.head + 1) > self.max_count do
    local entry = self.entries[self.head]
    if self.lookup[entry.key] == entry.timestamp then
      self.lookup[entry.key] = nil
    end
    self.head = self.head + 1
  end

  self:_compact_if_needed()
end

function Cache:contains(key)
  local now = self:_now()
  self:_cleanup(now)
  return self.lookup[key] ~= nil
end

function Cache:record(key)
  local now = self:_now()
  self:_cleanup(now)

  if self.lookup[key] ~= nil then
    return false
  end

  self.entries[#self.entries + 1] = {
    key = key,
    timestamp = now,
  }
  self.lookup[key] = now
  self:_cleanup(now)
  return true
end

function Cache:reset()
  self.entries = {}
  self.head = 1
  self.lookup = {}
end

M.Cache = Cache

function M.new(opts)
  return Cache:new(opts)
end

return M
