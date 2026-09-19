local n = tonumber(os.getenv("GX_SNAP_FRAME") or "2700")
local out = os.getenv("GX_SNAP_OUT")
local f = 0
gx_snap_sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f == n then manager.machine.video:snapshot() end
  if f == n + 2 then manager.machine:exit() end
end)
