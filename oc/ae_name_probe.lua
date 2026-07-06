local component = require("component")
local term = require("term")

-- Keep this list narrow on small OpenComputers machines.
-- Use {} to print every fluid name.
local FLUID_KEYWORDS = {
  "mag",
  "naq",
  "infinity",
  "temporal",
  "excited",
  "tec",
}

local function safeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function hasMethod(addr, name)
  local methods = safeCall(component.methods, addr)
  return methods ~= nil and methods[name] ~= nil
end

local function findMeInterface()
  for addr in component.list("me_interface", true) do
    if hasMethod(addr, "getFluidsInNetwork") or hasMethod(addr, "getInterfaceConfiguration") then
      return component.proxy(addr), addr
    end
  end
  error("no usable me_interface")
end

local function containsKeyword(text)
  if #FLUID_KEYWORDS == 0 then
    return true
  end

  text = tostring(text or ""):lower()
  for _, keyword in ipairs(FLUID_KEYWORDS) do
    if text:find(tostring(keyword):lower(), 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function stackAmount(stack)
  return stack.size or stack.amount or stack.qty or stack.count or 0
end

local function printStack(slot, stack)
  if type(stack) ~= "table" then
    return
  end
  if stack.name == nil and stack.label == nil and stack.size == nil and stack.amount == nil then
    return
  end

  print(string.format(
    "slot %d: name=%s, label=%s, damage=%s, amount=%s",
    slot,
    tostring(stack.name),
    tostring(stack.label),
    tostring(stack.damage),
    tostring(stackAmount(stack))
  ))
end

local me, addr = findMeInterface()
term.clear()
term.setCursor(1, 1)
print("ME interface: " .. tostring(addr))
print("")

print("Fluids from getFluidsInNetwork():")
if hasMethod(addr, "getFluidsInNetwork") then
  local fluids = safeCall(me.getFluidsInNetwork) or {}
  local rows = {}

  for _, fluid in ipairs(fluids) do
    if type(fluid) == "table" then
      local name = tostring(fluid.name or "")
      local label = tostring(fluid.label or "")
      if containsKeyword(name) or containsKeyword(label) then
        table.insert(rows, {
          name = name,
          label = label,
          amount = tonumber(fluid.amount) or 0,
        })
      end
    end
  end

  table.sort(rows, function(a, b)
    if a.name == b.name then
      return a.amount > b.amount
    end
    return a.name < b.name
  end)

  if #rows == 0 then
    print("  no matched fluids")
  else
    for _, row in ipairs(rows) do
      print(string.format(
        "  name=%s, label=%s, amount=%s",
        row.name,
        row.label,
        tostring(row.amount)
      ))
    end
  end
else
  print("  method missing")
end

print("")
print("Items from ME interface config slots:")
print("Put the item in an interface config slot, then run this again.")
if hasMethod(addr, "getInterfaceConfiguration") then
  local any = false
  for slot = 1, 81 do
    local stack = safeCall(me.getInterfaceConfiguration, slot)
    if type(stack) == "table" and (stack.name ~= nil or stack.label ~= nil) then
      any = true
      printStack(slot, stack)
    end
  end
  if not any then
    print("  no configured items")
  end
else
  print("  method missing")
end
