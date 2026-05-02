local WAIT_SEC = 1;
local rs = component.proxy(component.list("redstone")());
local chunkloader = component.proxy(component.list("chunkloader")());
local waitsec = 0;
local shouldAnchorEnable = false;

while true do
  local hasSignal = rs.getInput(0) ~= 0;

  if hasSignal then
    waitsec = waitsec + 1;
  else
    waitsec = 0;
  end

  shouldAnchorEnable = waitsec <= WAIT_SEC;

  print("hasSignal = " .. tostring(hasSignal)
    .. ", waitsec = " .. tostring(waitsec)
    .. ", shouldAnchorEnable = " .. tostring(shouldAnchorEnable));

  rs.setOutput(1, shouldAnchorEnable and 15 or 0);
  chunkloader.setActive(shouldAnchorEnable);
  computer.pullSignal(1);
end