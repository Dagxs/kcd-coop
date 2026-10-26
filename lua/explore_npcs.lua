local ok, err = pcall(function()
  local L = function(s) System.LogAlways('[coopnpc] ' .. s) end
  L('SpawnEnemy=' .. type(SpawnEnemy) .. ' SpawnFighters=' .. type(SpawnFighters) .. ' CombatDebug=' .. type(CombatDebug))
  local f = function(fn) local okf, r = pcall(fn) if okf then return tostring(r) end return 'ERR' end
  L('player faction=' .. f(function() return (AI.GetFactionOf(player.id)) end) .. ' health=' .. f(function() return player.actor:GetHealth() end) .. ' max=' .. f(function() return player.actor:GetMaxHealth() end))
  local p = player:GetWorldPos()
  local list = System.GetEntitiesInSphere(p, 80) or {}
  L('in sphere: ' .. #list)
  local n = 0
  for _, e in ipairs(list) do
    if e.actor and e.soul and e.id ~= player.id and n < 25 then
      n = n + 1
      L(string.format('%s cls=%s soul=%s fac=%s hostile=%s hp=%s/%s unc=%s st=%s drawn=%s danger=%s pos=%s',
        tostring(e:GetName()), tostring(e.class),
        f(function() return e.Properties.sharedSoulGuid end),
        f(function() return (AI.GetFactionOf(e.id)) end),
        f(function() return (AI.Hostile(e.id, player.id)) end),
        f(function() return (e.actor:GetHealth()) end), f(function() return (e.actor:GetMaxHealth()) end),
        f(function() return (e.actor:IsUnconscious()) end),
        f(function() return (e.actor:GetCurrentAnimationState()) end),
        f(function() return (e.human:IsWeaponDrawn()) end),
        f(function() return (e.soul:IsInCombatDanger()) end),
        f(function() local q = e:GetWorldPos() return string.format('%.1f,%.1f,%.1f', q.x, q.y, q.z) end)))
    end
  end
  if CoopP then L('standin faction=' .. f(function() return (AI.GetFactionOf(CoopP.id)) end) .. ' hostileToPlayer=' .. f(function() return (AI.Hostile(CoopP.id, player.id)) end)) end
  L('done')
end)
if not ok then System.LogAlways('[coopnpc] ERROR ' .. tostring(err)) end
