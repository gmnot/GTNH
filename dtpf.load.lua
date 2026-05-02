local WAIT_SEC = 1;
local rs = component.proxy(component.list("redstone")());
local chunkloader = component.proxy(component.list("chunkloader")());
local waitsec = 0;
local shouldAnchorEnable = false;
while true do
    waitsec = rs.getInput(0) ~= 0 and waitsec + 1 or 0;
    shouldAnchorEnable = waitsec <= WAIT_SEC
    rs.setOutput(1, shouldAnchorEnable and 15 or 0);
    chunkloader.setActive(shouldAnchorEnable);
    computer.pullSignal(1);
end
return 14;