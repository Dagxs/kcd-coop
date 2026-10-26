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

function CoopEnsurePuppet(x, y, z)
  if CoopP and CoopP.id and System.GetEntity(CoopP.id) then return CoopP end
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
  CoopAnimCur = nil
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

function CoopAnimate(e, spd)
  local cur = CoopAnimCur
  local s = CoopAnimSet
  local want = cur or s.idle
  if cur == s.run then
    if spd < 2.9 then want = s.walk end
    if spd < 0.3 then want = s.idle end
  elseif cur == s.walk then
    if spd > 3.5 then want = s.run elseif spd < 0.3 then want = s.idle end
  else
    if spd > 3.5 then want = s.run elseif spd > 0.7 then want = s.walk end
  end
  if CoopAnimCur ~= want or CoopAnimEnt ~= e.id then
    e:StartAnimation(0, want, 0, 0.3, 1.0, true)
    CoopAnimCur = want
    CoopAnimEnt = e.id
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

function CoopPlayOnce(e, name, blend)
  local len = 0
  pcall(function() len = e:GetAnimationLength(0, name) end)
  if not len or len <= 0 then return 0 end
  e:StartAnimation(0, name, 0, blend or 0.1, 1.0, false)
  CoopAnimCur = name
  return len
end

function CoopCombat(e, cstate)
  local now = CoopNow()
  CoopGuard = CoopGuard or 'rg'
  local busy = now < (CoopBusyUntil or 0)
  local fresh = cstate ~= CoopCombatPrev
  local len = 0
  if cstate == 2 and (fresh or not busy) then
    CoopGuard = (CoopGuard == 'rg') and 'lg' or 'rg'
    len = CoopPlayOnce(e, string.format(CoopCombatAnims.attack, CoopGuard, math.random(0, 4)), 0.08)
  elseif cstate == 4 and fresh then
    len = CoopPlayOnce(e, string.format(CoopCombatAnims.block, CoopGuard, math.random(0, 4)), 0.08)
  elseif cstate == 5 and fresh then
    len = CoopPlayOnce(e, string.format(CoopCombatAnims.hit, CoopGuard, math.random(0, 2)), 0.05)
  elseif cstate == 6 and fresh then
    len = CoopPlayOnce(e, string.format(CoopCombatAnims.dodge, CoopGuard), 0.08)
  end
  if len > 0 then
    CoopBusyUntil = now + len * 0.85
  elseif not busy then
    local st = string.format(CoopCombatAnims.stance, CoopGuard)
    if CoopAnimCur ~= st then
      e:StartAnimation(0, st, 0, 0.25, 1.0, true)
      CoopAnimCur = st
    end
  end
  CoopCombatPrev = cstate
end

function CoopSetRemote(x, y, z, rz, spd, drawn, cstate)
  local e = CoopEnsurePuppet(x, y, z)
  if not e then return end
  e:SetWorldPos({x = x, y = y, z = z})
  e:SetWorldAngles({x = 0, y = 0, z = rz})
  if drawn ~= nil and (drawn ~= CoopDrawnCur or CoopDrawnEnt ~= e.id) then
    CoopDrawnCur = drawn
    CoopDrawnEnt = e.id
    local okd, er = pcall(function()
      if drawn == 1 then e.human:DrawWeapon() else e.human:HolsterWeapon() end
    end)
    System.LogAlways('[coop] remote weapon ' .. (drawn == 1 and 'drawn' or 'holstered') .. ' ok=' .. tostring(okd) .. (okd and '' or (' ' .. tostring(er))))
  end
  if drawn == 1 then
    if cstate and cstate > 0 then pcall(CoopCombat, e, cstate) end
  else
    CoopCombatPrev = 0
    pcall(CoopAnimate, e, spd or 0)
  end
end

function CoopFakeFollow()
  if not player then return end
  local p = player:GetWorldPos()
  local a = player:GetWorldAngles()
  CoopSetRemote(p.x + 2, p.y, p.z, a.z, 0)
end

CoopCoreVersion = 6
System.LogAlways('[coop] core v6 defined')
