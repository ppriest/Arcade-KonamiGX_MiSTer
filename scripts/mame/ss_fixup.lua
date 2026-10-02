-- SPDX-License-Identifier: GPL-3.0-or-later
-- The second half of scripts/gxss.py to-mame. MAME is started with -state
-- on a state whose items gxss.py wrote; right after it loads (before
-- anything runs) this applies GX_SS_FIXUP, a line each:
--   w16 <hex address> <hex value>   a write by the main CPU's program space,
--                                   so the chip's own handler takes it
--   w32 <hex address> <hex value>
--   pc <cpu tag> <hex address>      the CPU's PC through its state
--                                   interface: MAME rebuilds the prefetch
--                                   and (68000) the decoder's state from it
-- then saves GX_SS_OUT (a state name), a microsecond of emulated time
-- later, and exits.
local fix = os.getenv("GX_SS_FIXUP")
local out = os.getenv("GX_SS_OUT")
local done, saved, frames = false, false, 0

gx_fix_load = emu.add_machine_post_load_notifier(function()
  if done then return end
  done = true
  local space = manager.machine.devices[":maincpu"].spaces["program"]
  local n = 0
  for ln in io.lines(fix) do
    local op, a, b = ln:match("^(%S+)%s+(%S+)%s+(%S+)")
    if op == "w16" then
      space:write_u16(tonumber(a, 16), tonumber(b, 16)); n = n + 1
    elseif op == "w32" then
      space:write_u32(tonumber(a, 16), tonumber(b, 16)); n = n + 1
    elseif op == "pc" then
      manager.machine.devices[a].state["PC"].value = tonumber(b, 16)
    end
  end
  print(string.format("GX_FIXUP %d writes", n))
  -- a save asked for here is dropped when the load finishes; one asked for
  -- a microsecond of emulated time later is taken at that timeslice's end
  coroutine.wrap(function()
    emu.wait(1e-6)
    manager.machine:save(out)
    saved = true
  end)()
end)

gx_fix_frame = emu.add_machine_frame_notifier(function()
  if saved then
    frames = frames + 1
    if frames == 2 then
      print("GX_FIXUP_OK")
      manager.machine:exit()
    end
  end
end)
