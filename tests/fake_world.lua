-- Minimal fake engine to exercise coop_core.lua outside the game (host and client in one Lua state each).
local T = 0
local ents, byid, nextid = {}, {}, 1
local log = {}
local function mk(name, cls, x, y, z, hostile)
  local e = {id = nextid, class = cls, name = name, pos = {x = x, y = y, z = z}, ang = {x = 0, y = 0, z = 0}, hp = 100, hostile = hostile, hidden = false, Properties = {sharedSoulGuid = 'abcd-12'}}
  nextid = nextid + 1
  function e:GetName() return self.name end
  function e:GetWorldPos() return {x = self.pos.x, y = self.pos.y, z = self.pos.z} end
  function e:GetWorldAngles() return self.ang end
  function e:SetWorldPos(p) self.pos = p end
  function e:SetWorldAngles(a) self.ang = a end
  function e:StartAnimation(...) self.anim = select(2, ...) end
  function e:GetAnimationLength() return 0.8 end
  function e:Hide(v) self.hidden = v == 1 end
  e.actor = {GetHealth = function() return e.hp end, GetMaxHealth = function() return 100 end, SetHealth = function(_, v) e.hp = v end,
    IsUnconscious = function() return false end, GetCurrentAnimationState = function() return e.state or 'MotionIdle' end,
    MakeLookAsSoul = function() end, MakeLookAsActor = function() end}
  e.soul = {IsInCombatDanger = function() return false end, DealDamage = function(_, h) e.hp = e.hp - h end, OverrideHead = function() end, OverrideHair = function() end}
  e.human = {IsWeaponDrawn = function() return e.drawn or false end, DrawWeapon = function() end, HolsterWeapon = function() end}
  e.inventory = {GetInventoryTable = function() return {} end}
  ents[#ents + 1] = e; byid[e.id] = e
  return e
end
System = {
  LogAlways = function(s) log[#log + 1] = s print(s) end,
  GetCurrTime = function() return T end,
  GetEntity = function(id) return byid[id] end,
  GetEntityByName = function(n) for _, e in ipairs(ents) do if e.name == n and byid[e.id] then return e end end end,
  GetEntitiesByClass = function(c) local r = {} for _, e in ipairs(ents) do if e.class == c and byid[e.id] then r[#r + 1] = e end end return r end,
  GetEntitiesInSphere = function(p, r) local o = {} for _, e in ipairs(ents) do if byid[e.id] then local q = e.pos if (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 < r * r then o[#o + 1] = e end end end return o end,
  SpawnEntity = function(t) return mk(t.name, t.class, t.position.x, t.position.y, t.position.z, false) end,
  RemoveEntity = function(id) byid[id] = nil end,
  SetCVar = function(k, v) CVAR = CVAR or {} CVAR[k] = v end,
}
AI = {SetBehaviorTreeEvaluationEnabled = function() end, Hostile = function(a, b) return byid[a] and byid[a].hostile or false end, AddPersonallyHostile = function() end}
__null = nil
return {mk = mk, tick = function(dt) T = T + dt end, ents = ents, log = log}
