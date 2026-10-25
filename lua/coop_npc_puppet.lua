local ok, err = pcall(function()
  CoopLook = {
    soul = '43144483-f3bb-fab8-9ceb-f77e3020598a',
    head = '4b8b7289-41e9-2785-a0b9-1651465445a5',
    hair = '4bc51034-3ad5-0050-f5c1-ba11046ed4ba',
  }
  local function remove(e) if e and e.id and System.GetEntity(e.id) then System.RemoveEntity(e.id) end end
  remove(CoopP)
  remove(CoopNpcTest)
  CoopP = nil
  CoopNpcTest = nil
  function CoopEnsurePuppet(x, y, z)
    if CoopP and CoopP.id and System.GetEntity(CoopP.id) then return CoopP end
    local e = System.SpawnEntity({class = 'NPC', name = 'coop_remote_henry', position = {x = x, y = y, z = z}})
    if not e then System.LogAlways('[coop] npc puppet spawn FAILED') CoopP = nil return nil end
    local function try(name, f) local okf, r = pcall(f) System.LogAlways('[coop] puppet ' .. name .. ' ok=' .. tostring(okf)) end
    try('brain off', function() AI.SetBehaviorTreeEvaluationEnabled(e.id, false) end)
    try('look soul', function() e.actor:MakeLookAsSoul(CoopLook.soul) end)
    try('head', function() e.soul:OverrideHead(CoopLook.head) end)
    try('hair', function() e.soul:OverrideHair(CoopLook.hair) end)
    try('clothes', function() e.actor:MakeLookAsActor(player.id) end)
    System.LogAlways('[coop] npc puppet spawned id=' .. tostring(e.id))
    CoopP = e
    CoopAnimCur = nil
    return e
  end
  System.LogAlways('[coop] npc puppet installed')
end)
if not ok then System.LogAlways('[coop] npc puppet ERROR ' .. tostring(err)) end
