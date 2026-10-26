local ok, er = pcall(function()
  local L = function(s) System.LogAlways('[coopprobe] ' .. s) end
  local n = 0
  for _, e in ipairs(System.GetEntitiesByClass('NPC') or {}) do
    if e:GetName() == 'SpawnedEnemy_01' then
      n = n + 1
      local q = e:GetWorldPos()
      local hp, st, hid = '?', '?', '?'
      pcall(function() hp = tostring(e.actor:GetHealth()) end)
      pcall(function() st = tostring(e.actor:GetCurrentAnimationState()) end)
      pcall(function() hid = tostring(e:IsHidden()) end)
      L(string.format('bandit id=%s hp=%s st=%s hidden=%s pos=%.1f,%.1f,%.1f hostile=%s', tostring(e.id), hp, st, hid, q.x, q.y, q.z, tostring(AI.Hostile(e.id, player.id))))
    end
  end
  local p = player:GetWorldPos()
  L(string.format('bandits=%d role=%s player=%.1f,%.1f,%.1f hp=%s suppressed=%s', n, tostring(CoopRole), p.x, p.y, p.z, tostring(player.actor:GetHealth()), tostring(CoopSuppressed and CoopSuppressed.SpawnedEnemy_01)))
end)
if not ok then System.LogAlways('[coopprobe] ERROR ' .. tostring(er)) end
