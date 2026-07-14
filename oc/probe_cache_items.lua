local component = require("component")
local sides = require("sides")

local trans = component.transposer
local sideCacheBuffer = sides.down

for slot = 1, 7 do
  local item = trans.getStackInSlot(sideCacheBuffer, slot)
  if item ~= nil then
    print(string.format(
      "slot=%d name=%s label=%s damage=%s size=%s",
      slot,
      tostring(item.name),
      tostring(item.label),
      tostring(item.damage),
      tostring(item.size)
    ))
  end
end
