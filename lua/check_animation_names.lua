local ok, err = pcall(function()
  local e = CoopP
  if not e then System.LogAlways('[coopanimtest] no puppet') return end
  local names = {'1d_relaxed_idle_bigturns_nw', '2d_relaxed_walk_strafe_spd_fwd', '2d_relaxed_run_strafe_spd_fwd',
    '2d_relaxed_walk_strafe_spd_fwd_ext', '2d_relaxed_run_strafe_spd_fwd_ext', '3d_relaxed_walk_turn_strafe',
    '3d_relaxed_run_turn_strafe', '2d_relaxed_walk_turn_spd_fwd', 'relaxed_idle_nw', 'relaxed_walk_nw_fwd',
    'relaxed_run_nw_fwd', 'idle', 'walk', 'run'}
  for _, n in ipairs(names) do
    local okl, len = pcall(function() return e:GetAnimationLength(0, n) end)
    System.LogAlways('[coopanimtest] ' .. n .. ' len=' .. tostring(len) .. ' ok=' .. tostring(okl))
  end
  local oks, r = pcall(function() return e:StartAnimation(0, '2d_relaxed_walk_strafe_spd_fwd', 0, 0.2, 1.0, true) end)
  System.LogAlways('[coopanimtest] start walk ok=' .. tostring(oks) .. ' r=' .. tostring(r))
end)
if not ok then System.LogAlways('[coopanimtest] ERROR ' .. tostring(err)) end
