local ok, er = pcall(function()
  local L = function(s) System.LogAlways('[coopout] ' .. s) end
  L('role=' .. tostring(CoopRole) .. ' out=' .. tostring(CoopOut and #CoopOut) .. ' tickerr=' .. tostring(CoopTickErr) .. ' pw=' .. string.sub(tostring(System.GetCVar('sv_password')), 1, 200))
  local okp, pick = pcall(CoopHostPick, CoopNow())
  if not okp then L('pick error ' .. tostring(pick)) else
    for nm, e in pairs(pick) do L('pick ' .. nm) end
  end
  local okt, e2 = pcall(CoopTick)
  L('tick ok=' .. tostring(okt) .. ' ' .. tostring(e2))
  local okf, e3 = pcall(CoopFlush, 999999)
  L('flush ok=' .. tostring(okf) .. ' ' .. tostring(e3) .. ' pw=' .. string.sub(tostring(System.GetCVar('sv_password')), 1, 200))
end)
if not ok then System.LogAlways('[coopout] ERROR ' .. tostring(er)) end
