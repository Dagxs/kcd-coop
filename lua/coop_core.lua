-- coop_core.lua: game-side half of kcd-coop. Embedded into dinput8.dll at build time (tools/embed_lua.py)
-- and run through the console, so: no Lua line comments after code on the same line (lines are joined).
-- tools/embed_lua.py splits it into chunks at blank lines and wraps each in a version guard, so re-running
-- it is a no-op once CoopCoreVersion is current (set by the last chunk).

CoopLook = {
  soul = '43144483-f3bb-fab8-9ceb-f77e3020598a',
  head = '4b8b7289-41e9-2785-a0b9-1651465445a5',
  hair = '4bc51034-3ad5-0050-f5c1-ba11046ed4ba',
}

CoopAnimSet = {
  idle = '1d_relaxed_idle_bigturns_nw',
  walk = '2d_relaxed_walk_strafe_spd_fwd',
  run = '2d_relaxed_run_strafe_spd_fwd',
}

function CoopFindPuppet()
  local keep = nil
  for _, e in ipairs(System.GetEntitiesByClass('NPC') or {}) do
    if e:GetName() == 'coop_remote_henry' then
      if not keep then keep = e else System.RemoveEntity(e.id) System.LogAlways('[coop] removed duplicate stand-in') end
    end
  end
  return keep
end

function CoopEnsurePuppet(x, y, z)
  if CoopP and CoopP.id and System.GetEntity(CoopP.id) then return CoopP end
  local found = CoopFindPuppet()
  if found then
    CoopP = found
    CoopPS = {}
    System.LogAlways('[coop] reusing stand-in id=' .. tostring(found.id))
    return found
  end
  local e = System.SpawnEntity({class = 'NPC', name = 'coop_remote_henry', position = {x = x, y = y, z = z}})
  if not e then System.LogAlways('[coop] puppet spawn FAILED') CoopP = nil return nil end
  local function try(name, f)
    local okf, r = pcall(f)
    if not okf then System.LogAlways('[coop] puppet ' .. name .. ' failed: ' .. tostring(r)) end
  end
  try('brain off', function() AI.SetBehaviorTreeEvaluationEnabled(e.id, false) end)
  try('look soul', function() e.actor:MakeLookAsSoul(CoopLook.soul) end)
  try('head', function() e.soul:OverrideHead(CoopLook.head) end)
  try('hair', function() e.soul:OverrideHair(CoopLook.hair) end)
  if not CoopGearLast and player then try('clothes', function() e.actor:MakeLookAsActor(player.id) end) end
  System.LogAlways('[coop] puppet spawned id=' .. tostring(e.id))
  CoopP = e
  CoopPS = {}
  CoopGearItems = {}
  if CoopGearLast then CoopDressRemote(CoopGearLast) end
  return e
end

function CoopProbePublish()
  if not player then return end
  local pick = nil
  for k, v in pairs(player.inventory:GetInventoryTable() or {}) do
    local nm = ''
    pcall(function() nm = tostring(ItemManager.GetItemName(ItemManager.GetItem(v).class)) end)
    if not pick or string.find(nm, 'keyring') then pick = v end
  end
  CoopProbeItem = pick
  if pick then System.SetCVar('sv_servername', 'W ' .. tostring(pick)) end
end

function CoopProbeEquip()
  if player and CoopProbeItem then player.actor:EquipInventoryItem(CoopProbeItem) end
end

function CoopReportWorn(hexlist)
  if not player then return end
  local want = {}
  for h in string.gmatch(hexlist, '%x+') do want[string.lower(h)] = true end
  local classes = {}
  for k, v in pairs(player.inventory:GetInventoryTable() or {}) do
    local key = string.lower(string.match(tostring(v), '(%x+)$') or '')
    key = string.gsub(key, '^0+', '')
    if want[key] then
      local it = ItemManager.GetItem(v)
      if it then classes[#classes + 1] = it.class end
    end
  end
  table.sort(classes)
  System.SetCVar('sv_servername', 'G ' .. table.concat(classes, ','))
end

function CoopInvSet(ent)
  local t = {}
  for k, v in pairs(ent.inventory:GetInventoryTable() or {}) do t[tostring(v)] = v end
  return t
end

function CoopDressRemote(list)
  CoopGearLast = list
  local e = CoopP
  if not e or not e.id or not System.GetEntity(e.id) then return end
  for _, id in ipairs(CoopGearItems or {}) do
    pcall(function() e.actor:UnequipInventoryItem(id) end)
    pcall(function() e.inventory:DeleteItem(id, 1) end)
  end
  CoopGearItems = {}
  pcall(function() e.actor:MakeLookAsSoul(CoopLook.soul) end)
  pcall(function() e.soul:OverrideHead(CoopLook.head) end)
  pcall(function() e.soul:OverrideHair(CoopLook.hair) end)
  local n = 0
  for cls in string.gmatch(list, '[^,]+') do
    local before = CoopInvSet(e)
    pcall(function() e.inventory:CreateItem(cls, 1, 1) end)
    local newid = nil
    for k, v in pairs(CoopInvSet(e)) do if not before[k] then newid = v end end
    if newid then
      local oke, er = pcall(function() e.actor:EquipInventoryItem(newid) end)
      if not oke then System.LogAlways('[coop] equip failed: ' .. tostring(er)) end
      CoopGearItems[#CoopGearItems + 1] = newid
      n = n + 1
    else
      System.LogAlways('[coop] could not create item ' .. cls)
    end
  end
  System.LogAlways('[coop] dressed remote with ' .. n .. ' items')
end

function CoopAnimate(e, spd, st)
  local cur = st.cur
  local s = CoopAnimSet
  local want = s.idle
  if cur == s.run then
    want = s.run
    if spd < 2.9 then want = s.walk end
    if spd < 0.3 then want = s.idle end
  elseif cur == s.walk then
    want = s.walk
    if spd > 3.5 then want = s.run elseif spd < 0.3 then want = s.idle end
  else
    if spd > 3.5 then want = s.run elseif spd > 0.7 then want = s.walk end
  end
  if st.cur ~= want then
    e:StartAnimation(0, want, 0, 0.3, 1.0, true)
    st.cur = want
  end
end

CoopCombatAnims = {
  stance = 'combat_%s_z0_idle01_lngsw',
  attack = '1d-combat_%s_z%d_natksw_lngsw',
  block = '1d-combat_%s_z%d_nblksw_lngsw',
  hit = 'combat_%s_z%d_hitst_z5_lngsw',
  dodge = 'combat_%s_z0_dodge_back_lngsw',
}

function CoopNow()
  local t = 0
  pcall(function() t = System.GetCurrTime() end)
  return t
end

function CoopPlayOnce(e, name, blend, st)
  local len = 0
  pcall(function() len = e:GetAnimationLength(0, name) end)
  if not len or len <= 0 then return 0 end
  e:StartAnimation(0, name, 0, blend or 0.1, 1.0, false)
  st.cur = name
  return len
end

function CoopCombat(e, cstate, st)
  local now = CoopNow()
  st.guard = st.guard or 'rg'
  local busy = now < (st.busy or 0)
  local fresh = cstate ~= st.prev
  local A = CoopCombatAnims
  local len = 0
  if cstate == 2 and (fresh or not busy) then
    st.guard = (st.guard == 'rg') and 'lg' or 'rg'
    len = CoopPlayOnce(e, string.format(A.attack, st.guard, math.random(0, 4)), 0.08, st)
  elseif cstate == 4 and fresh then
    len = CoopPlayOnce(e, string.format(A.block, st.guard, math.random(0, 4)), 0.08, st)
  elseif cstate == 5 and fresh then
    len = CoopPlayOnce(e, string.format(A.hit, st.guard, math.random(0, 2)), 0.05, st)
  elseif cstate == 6 and fresh then
    len = CoopPlayOnce(e, string.format(A.dodge, st.guard), 0.08, st)
  end
  if len > 0 then
    st.busy = now + len * 0.85
  elseif not busy then
    local sn = string.format(A.stance, st.guard)
    if st.cur ~= sn then
      e:StartAnimation(0, sn, 0, 0.25, 1.0, true)
      st.cur = sn
    end
  end
  st.prev = cstate
end

function CoopDrive(e, st, drawn, cstate, spd)
  if drawn ~= nil and drawn ~= st.drawn then
    st.drawn = drawn
    pcall(function() if drawn == 1 then e.human:DrawWeapon() else e.human:HolsterWeapon() end end)
  end
  if drawn == 1 and cstate and cstate > 0 then
    pcall(CoopCombat, e, cstate, st)
  else
    st.prev = 0
    pcall(CoopAnimate, e, spd or 0, st)
  end
end

function CoopSetRemote(x, y, z, rz, spd, drawn, cstate)
  local e = CoopEnsurePuppet(x, y, z)
  if not e then return end
  CoopPS = CoopPS or {}
  e:SetWorldPos({x = x, y = y, z = z})
  e:SetWorldAngles({x = 0, y = 0, z = rz})
  CoopDrive(e, CoopPS, drawn, cstate, spd)
end

CoopOut = CoopOut or {}
CoopEn = CoopEn or {}
CoopHostSeen = CoopHostSeen or {}

function CoopSend(m)
  if #CoopOut < 80 then CoopOut[#CoopOut + 1] = m end
end

function CoopIsHost()
  return CoopRole == 'A'
end

function CoopNum(v)
  return string.format('%.2f', v or 0)
end

function CoopEnemyCandidate(e)
  if not e or not e.actor or not e.soul or not e.human then return false end
  if player and e.id == player.id then return false end
  local nm = e:GetName() or ''
  if string.find(nm, 'coop_') == 1 or nm == '' then return false end
  local alive = true
  pcall(function() if e.actor:GetHealth() <= 0 or e.actor:IsUnconscious() then alive = false end end)
  if not alive then return false end
  local yes = false
  pcall(function() if AI.Hostile(e.id, player.id) then yes = true end end)
  pcall(function() if e.soul:IsInCombatDanger() then yes = true end end)
  pcall(function() if e.actor:GetHealth() < e.actor:GetMaxHealth() then yes = true end end)
  return yes
end

function CoopStateCode(e)
  local c = 0
  pcall(function()
    local s = tostring(e.actor:GetCurrentAnimationState())
    if string.find(s, 'Combat') == 1 or string.find(s, 'Free') == 1 then
      c = 1
      if string.find(s, 'Attack') then c = 2 elseif string.find(s, 'Dodge') then c = 6
      elseif string.find(s, 'Hit') or string.find(s, 'BlockBroken') then c = 5
      elseif string.find(s, 'Block') then c = 4 elseif string.find(s, 'Movement') then c = 3 end
    end
  end)
  return c
end

function CoopHostPick(now)
  local centers = {player:GetWorldPos()}
  if CoopP and System.GetEntity(CoopP.id) then centers[#centers + 1] = CoopP:GetWorldPos() end
  local pick, cand = {}, {}
  for _, c in ipairs(centers) do
    for _, e in ipairs(System.GetEntitiesInSphere(c, 100) or {}) do
      local nm = e.GetName and e:GetName()
      if nm and e.actor and e.human and string.find(nm, 'coop_') ~= 1 and not cand[nm] then
        local q = e:GetWorldPos()
        local near = (q.x - c.x) ^ 2 + (q.y - c.y) ^ 2 < 3600
        local isc = CoopEnemyCandidate(e)
        local seen = CoopHostSeen[nm] and now - CoopHostSeen[nm] < 4
        if (isc and (near or seen)) or (seen and not pick[nm]) then
          pick[nm] = e
          if isc then cand[nm] = true end
        end
      end
    end
  end
  return pick
end

function CoopHostEnemies()
  local now = CoopNow()
  local pick = CoopHostPick(now)
  local n = 0
  for nm, e in pairs(pick) do
    if n < 10 then
      n = n + 1
      if CoopEnemyCandidate(e) then CoopHostSeen[nm] = now end
      local p = e:GetWorldPos()
      local a = e:GetWorldAngles()
      local hp, dead, drawn = 100, 0, 0
      pcall(function() hp = e.actor:GetHealth() end)
      if hp <= 0 then dead = 1 end
      pcall(function() if e.actor:IsUnconscious() then dead = 1 end end)
      pcall(function() if e.human:IsWeaponDrawn() then drawn = 1 end end)
      local soul = ''
      pcall(function() soul = tostring(e.Properties.sharedSoulGuid or '') end)
      if not string.match(soul, '^[%x%-]+$') then soul = '' end
      CoopSend(table.concat({'E', nm, soul, CoopNum(p.x), CoopNum(p.y), CoopNum(p.z), string.format('%.3f', a.z), CoopNum(hp), tostring(dead + drawn * 2), tostring(CoopStateCode(e))}, ';'))
      CoopHostileSet = CoopHostileSet or {}
      if CoopP and CoopHostileSet and not CoopHostileSet[nm] then
        local hostile = false
        pcall(function() hostile = AI.Hostile(e.id, player.id) end)
        if hostile then
          CoopHostileSet[nm] = true
          local okh, er = pcall(function() AI.AddPersonallyHostile(e.id, CoopP.id) end)
          System.LogAlways('[coop] ' .. nm .. ' now hostile to stand-in ok=' .. tostring(okh) .. ' ' .. tostring(er or ''))
        end
      end
    end
  end
end

function CoopStandinHurt()
  if not CoopP or not System.GetEntity(CoopP.id) then return end
  local hp = 100
  pcall(function() hp = CoopP.actor:GetHealth() end)
  if hp < 99.5 then
    CoopSend('H;' .. CoopNum(100 - hp))
    pcall(function() CoopP.actor:SetHealth(100) end)
    System.LogAlways('[coop] stand-in took ' .. CoopNum(100 - hp) .. ' damage, relayed')
  end
end

function CoopEnemyApply(f)
  local nm, soul = f[2], f[3]
  local x, y, z, rz, hp = tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7]), tonumber(f[8])
  local flags, cs = tonumber(f[9]) or 0, tonumber(f[10]) or 0
  if not (nm and x and y and z and rz and hp) then return end
  local st = CoopEn[nm]
  local now = CoopNow()
  if st and (not st.e or not System.GetEntity(st.e.id)) then st = nil end
  if not st then
    local e = System.GetEntityByName(nm)
    local spawned = false
    if not e then
      local props = {}
      if soul and soul ~= '' then props.sharedSoulGuid = soul end
      e = System.SpawnEntity({class = 'NPC', name = nm, position = {x = x, y = y, z = z}, properties = props})
      spawned = true
    end
    if not e then return end
    pcall(function() AI.SetBehaviorTreeEvaluationEnabled(e.id, false) end)
    st = {e = e, spawned = spawned, x = x, y = y, z = z, rz = rz, tx = x, ty = y, tz = z, tr = rz, spd = 0, exp = 100}
    pcall(function() st.exp = e.actor:GetHealth() end)
    CoopEn[nm] = st
    System.LogAlways('[coop] enemy ' .. nm .. (spawned and ' spawned as proxy' or ' taken over'))
  end
  local dt = now - (st.t or now)
  if dt > 0.02 then
    local d = math.sqrt((x - st.tx) ^ 2 + (y - st.ty) ^ 2) / dt
    if d < 30 then st.spd = st.spd * 0.5 + d * 0.5 end
  end
  st.tx, st.ty, st.tz, st.tr, st.t = x, y, z, rz, now
  st.flags, st.cs, st.hhp = flags, cs, hp
  if flags % 2 == 1 and not st.dead then
    st.dead = true
    pcall(function() st.e.soul:DealDamage(1000, 1000, __null, true) end)
    System.LogAlways('[coop] enemy ' .. nm .. ' died on host')
  end
  if not st.dead and hp < st.exp - 0.5 then
    pcall(function() st.e.actor:SetHealth(hp) end)
    st.exp = hp
  end
end

function CoopEnemyStep()
  local now = CoopNow()
  for nm, st in pairs(CoopEn) do
    local e = st.e
    if not e or not System.GetEntity(e.id) then
      CoopEn[nm] = nil
    elseif now - (st.t or now) > 3 then
      if st.spawned and not st.dead then System.RemoveEntity(e.id)
      elseif not st.dead then pcall(function() AI.SetBehaviorTreeEvaluationEnabled(e.id, true) end) end
      CoopEn[nm] = nil
      System.LogAlways('[coop] enemy ' .. nm .. ' released')
    elseif not st.dead then
      local k = 0.35
      local dx, dy, dz = st.tx - st.x, st.ty - st.y, st.tz - st.z
      if dx * dx + dy * dy + dz * dz > 25 then k = 1 end
      st.x, st.y, st.z = st.x + dx * k, st.y + dy * k, st.z + dz * k
      local dr = st.tr - st.rz
      while dr > math.pi do dr = dr - 2 * math.pi end
      while dr < -math.pi do dr = dr + 2 * math.pi end
      st.rz = st.rz + dr * k
      e:SetWorldPos({x = st.x, y = st.y, z = st.z})
      e:SetWorldAngles({x = 0, y = 0, z = st.rz})
      if now - (st.t or now) > 1 then st.spd = 0 end
      local drawn = (math.floor((st.flags or 0) / 2) % 2 == 1) and 1 or 0
      CoopDrive(e, st, drawn, st.cs or 0, st.spd)
      local hp = st.exp
      pcall(function() hp = e.actor:GetHealth() end)
      if hp < st.exp - 0.5 then
        CoopSend('D;' .. nm .. ';' .. CoopNum(st.exp - hp))
        System.LogAlways('[coop] hit ' .. nm .. ' for ' .. CoopNum(st.exp - hp) .. ', sent to host')
        st.exp = hp
      end
    end
  end
end

function CoopSuppressLocal()
  if not player then return end
  for _, e in ipairs(System.GetEntitiesInSphere(player:GetWorldPos(), 40) or {}) do
    local nm = e.GetName and e:GetName()
    if nm and not CoopEn[nm] and e.actor and e.human and CoopEnemyCandidate(e) then
      CoopSuppressed = CoopSuppressed or {}
      if not CoopSuppressed[nm] then
        CoopSuppressed[nm] = true
        pcall(function() AI.SetBehaviorTreeEvaluationEnabled(e.id, false) end)
        pcall(function() e:Hide(1) end)
        System.LogAlways('[coop] hid local enemy ' .. nm .. ' (host world wins)')
      end
    end
  end
end

function CoopRecv(payload)
  for msg in string.gmatch(payload, '[^|]+') do
    local f = {}
    for v in string.gmatch(msg, '[^;]+') do f[#f + 1] = v end
    if f[1] == 'E' and not CoopIsHost() then
      pcall(CoopEnemyApply, f)
    elseif f[1] == 'D' and CoopIsHost() then
      local e = System.GetEntityByName(f[2] or '')
      local amt = tonumber(f[3] or '')
      if e and amt and e.soul then
        local okd, er = pcall(function() e.soul:DealDamage(amt, 0, __null, true) end)
        pcall(function() if CoopP then AI.AddPersonallyHostile(e.id, CoopP.id) end end)
        System.LogAlways('[coop] remote player hit ' .. f[2] .. ' for ' .. CoopNum(amt) .. ' ok=' .. tostring(okd) .. ' ' .. tostring(er or ''))
      end
    elseif f[1] == 'H' then
      local amt = tonumber(f[2] or '')
      if amt and player then
        local okd, er = pcall(function() player.soul:DealDamage(amt, 0, __null, true) end)
        System.LogAlways('[coop] took ' .. CoopNum(amt) .. ' damage from the other world ok=' .. tostring(okd) .. ' ' .. tostring(er or ''))
      end
    end
  end
end

function CoopTick()
  if not player then return end
  local now = CoopNow()
  CoopStandinHurt()
  if CoopIsHost() then
    if now - (CoopLastHost or 0) > 0.095 then
      CoopLastHost = now
      CoopHostEnemies()
    end
  else
    CoopEnemyStep()
    if now - (CoopLastSup or 0) > 0.5 then
      CoopLastSup = now
      CoopSuppressLocal()
    end
  end
end

function CoopFlush(seq)
  local okt, er = pcall(CoopTick)
  if not okt then
    CoopTickErr = (CoopTickErr or 0) + 1
    if CoopTickErr < 5 then System.LogAlways('[coop] tick error: ' .. tostring(er)) end
  end
  local out, len, i = {}, 0, 1
  while i <= #CoopOut and len + #CoopOut[i] < 1150 do
    out[#out + 1] = CoopOut[i]
    len = len + #CoopOut[i] + 1
    i = i + 1
  end
  local rest = {}
  for j = i, #CoopOut do rest[#rest + 1] = CoopOut[j] end
  CoopOut = rest
  System.SetCVar('sv_password', tostring(seq) .. '|' .. table.concat(out, '|'))
end

function CoopFakeFollow()
  if not player then return end
  local p = player:GetWorldPos()
  local a = player:GetWorldAngles()
  CoopSetRemote(p.x + 2, p.y, p.z, a.z, 0)
end

CoopCoreVersion = 8
System.LogAlways('[coop] core v8 defined')
