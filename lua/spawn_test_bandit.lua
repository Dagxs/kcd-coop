local ok, er = pcall(function()
  local p = player:GetWorldPos()
  local a = player:GetWorldAngles()
  local x, y = p.x - math.sin(a.z) * 6, p.y + math.cos(a.z) * 6
  local e = System.SpawnEntity({class = 'NPC', name = 'SpawnedEnemy_01', position = {x = x, y = y, z = p.z}, properties = {sharedSoulGuid = '44853669-3db0-d315-9180-f6b4cea54899'}})
  pcall(function() e.actor:EquipWeaponPreset('49b5c516-b2d9-ada9-2a77-44a8ca1a2182') end)
  pcall(function() AI.AddPersonallyHostile(e.id, player.id) end)
  System.LogAlways('[coop] test bandit spawned hostile=' .. tostring(AI.Hostile(e.id, player.id)))
end)
if not ok then System.LogAlways('[coop] test bandit failed: ' .. tostring(er)) end
