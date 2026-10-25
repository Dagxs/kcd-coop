local ok, err = pcall(function()
  local function keys(name, t)
    if type(t) ~= 'table' and type(t) ~= 'userdata' then System.LogAlways('[cooplook] ' .. name .. ' = ' .. type(t)) return end
    local out = {}
    if type(t) == 'table' then for k, v in pairs(t) do out[#out + 1] = tostring(k) .. ':' .. type(v) end end
    local mt = getmetatable(t)
    if mt and type(mt.__index) == 'table' then for k, v in pairs(mt.__index) do out[#out + 1] = '^' .. tostring(k) end end
    table.sort(out)
    local line = ''
    for _, s in ipairs(out) do
      line = line .. s .. ' '
      if #line > 900 then System.LogAlways('[cooplook] ' .. name .. ': ' .. line) line = '' end
    end
    System.LogAlways('[cooplook] ' .. name .. ': ' .. line)
  end
  keys('player', player)
  for _, n in ipairs({'actor', 'human', 'inventory', 'soul', 'player'}) do keys('player.' .. n, player[n]) end
  local n = 0
  local function scan(d, depth)
    if depth > 7 or n > 200 then return end
    for _, f in ipairs(System.ScanDirectory(d, 1) or {}) do
      if string.find(string.lower(f), 'henry') then n = n + 1 System.LogAlways('[cooplookfile] ' .. d .. '/' .. f) end
    end
    for _, sd in ipairs(System.ScanDirectory(d, 2) or {}) do scan(d .. '/' .. sd, depth + 1) end
  end
  scan('Objects/characters/humans', 0)
  System.LogAlways('[cooplook] done files=' .. n)
end)
if not ok then System.LogAlways('[cooplook] ERROR ' .. tostring(err)) end
