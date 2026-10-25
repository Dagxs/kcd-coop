local ok, err = pcall(function()
  local n = 0
  local function scan(d, depth)
    if depth > 6 or n > 800 then return end
    local fs = System.ScanDirectory(d, 1) or {}
    for _, f in ipairs(fs) do
      local l = string.lower(f)
      if string.find(l, 'walk') or string.find(l, 'run') or string.find(l, 'idle') or string.find(l, 'loco') then
        n = n + 1
        System.LogAlways('[coopanim] ' .. d .. '/' .. f)
      end
    end
    local ds = System.ScanDirectory(d, 2) or {}
    for _, sd in ipairs(ds) do scan(d .. '/' .. sd, depth + 1) end
  end
  local roots = System.ScanDirectory('Animations', 2) or {}
  System.LogAlways('[coopanim] roots: ' .. table.concat(roots, ','))
  scan('Animations/humans/male', 0)
  System.LogAlways('[coopanim] done, matches=' .. n)
end)
if not ok then System.LogAlways('[coopanim] ERROR ' .. tostring(err)) end
