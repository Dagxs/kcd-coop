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
    System.LogAlways('[coop] puppet anim -> ' .. want .. ' (speed ' .. string.format('%.2f', spd) .. ')')
  end
end
System.LogAlways('[coop] CoopAnimate v2 installed')
