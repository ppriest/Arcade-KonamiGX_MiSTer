-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dumps MAME's save-state registry for the running set: one line an item,
--   index <TAB> size <TAB> count <TAB> device tag <TAB> name
-- in index order (the order MAME writes them into a .sta). Then saves a
-- state named by GX_SS_STATE, if set, and exits.
--   GX_SS_OUT    the table's path
--   GX_SS_FRAME  frame to do it at (default 600)
--   GX_SS_STATE  state name for machine:save (optional)
local n = tonumber(os.getenv("GX_SS_FRAME") or "600")
local out = os.getenv("GX_SS_OUT")
local st = os.getenv("GX_SS_STATE")
local f = 0
local function dump()
  local names = {}
  for tag, dev in pairs(manager.machine.devices) do
    for name, idx in pairs(dev.items) do names[idx] = { tag, name } end
  end
  local h = io.open(out, "w")
  local i = 0
  while true do
    local it = emu.item(i)
    if it.size == 0 then break end
    local nm = names[i] or { "?", "?" }
    h:write(string.format("%d\t%d\t%d\t%s\t%s\n", i, it.size, it.count, nm[1], nm[2]))
    i = i + 1
  end
  h:close()
end
gx_ss_sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f == n then
    dump()
    if st then manager.machine:save(st) end
  end
  if f == n + 2 then manager.machine:exit() end
end)
