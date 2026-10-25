local ok, err = pcall(function()
  for k, v in pairs(player.inventory:GetInventoryTable() or {}) do
    local it = ItemManager.GetItem(v)
    local nm = '?'
    pcall(function() nm = tostring(ItemManager.GetItemName(it.class)) end)
    local ui = '?'
    pcall(function() ui = tostring(ItemManager.GetItemUIName(it.class)) end)
    System.LogAlways(string.format('[coopgearlist] %s class=%s name=%s ui=%s entity=%s health=%s amount=%s', tostring(k), tostring(it.class), nm, ui, tostring(it.entity), tostring(it.health), tostring(it.amount)))
  end
end)
if not ok then System.LogAlways('[coopgearlist] ERROR ' .. tostring(err)) end
