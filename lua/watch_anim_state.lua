CoopWatchN = 0
CoopWatchLast = nil
function CoopWatchTick()
  CoopWatchN = CoopWatchN + 1
  local ok, st = pcall(function() return player.actor:GetCurrentAnimationState() end)
  local s = tostring(st)
  if type(st) == 'table' then
    local parts = {}
    for k, v in pairs(st) do parts[#parts + 1] = tostring(k) .. '=' .. tostring(v) end
    table.sort(parts)
    s = table.concat(parts, ' ')
  end
  if s ~= CoopWatchLast then
    System.LogAlways('[coopanimstate] ' .. tostring(ok) .. ' ' .. s)
    CoopWatchLast = s
  end
  if CoopWatchN < 400 then Script.SetTimer(50, CoopWatchTick) end
end
System.LogAlways('[coopanimstate] watching for 20 s')
Script.SetTimer(50, CoopWatchTick)
