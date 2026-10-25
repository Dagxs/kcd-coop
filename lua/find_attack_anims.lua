local ok, err = pcall(function()
  local e = CoopP
  local found, n = 0, 0
  local function scan(d, depth)
    if depth > 6 or n > 400 then return end
    for _, f in ipairs(System.ScanDirectory(d, 1) or {}) do
      local l = string.lower(f)
      if string.find(l, 'attack') or string.find(l, 'block') or string.find(l, 'parry') or string.find(l, 'slash') or string.find(l, 'stab') then
        n = n + 1
        local base = string.gsub(f, '%.%w+$', '')
        local len = 0
        if e then pcall(function() len = e:GetAnimationLength(0, base) end) end
        if len and len > 0 then found = found + 1 System.LogAlways(string.format('[coopatk] OK %.2f %s/%s', len, d, f)) end
      end
    end
    for _, sd in ipairs(System.ScanDirectory(d, 2) or {}) do scan(d .. '/' .. sd, depth + 1) end
  end
  scan('Animations/humans/male', 0)
  System.LogAlways('[coopatk] done matches=' .. n .. ' playable=' .. found)
end)
if not ok then System.LogAlways('[coopatk] ERROR ' .. tostring(err)) end
