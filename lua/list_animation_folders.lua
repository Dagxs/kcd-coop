local ok, err = pcall(function()
  local function tree(d, depth)
    if depth > 2 then return end
    local fs = System.ScanDirectory(d, 1) or {}
    local ds = System.ScanDirectory(d, 2) or {}
    local sample = {}
    for i = 1, math.min(6, #fs) do sample[#sample + 1] = fs[i] end
    System.LogAlways('[cooptree] ' .. d .. ' files=' .. #fs .. ' dirs=' .. #ds .. ' e.g. ' .. table.concat(sample, ','))
    for _, sd in ipairs(ds) do tree(d .. '/' .. sd, depth + 1) end
  end
  tree('Animations/humans/male', 0)
  tree('Animations/mannequin', 1)
  System.LogAlways('[cooptree] done')
end)
if not ok then System.LogAlways('[cooptree] ERROR ' .. tostring(err)) end
