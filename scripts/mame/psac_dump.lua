-- soccerss: the K053936 (PSAC2) state at four vblanks from T3_T seconds, for
-- scripts/psac2_model.py. At each vblank acknowledgement (0xd4c01c) the
-- registers, line control, both palettes and the bank, then a snapshot of
-- both screens. The game writes the bank, registers and line control just
-- after the acknowledgement, for the next render, so dump n is the state of
-- snapshot n's picture.
--
--   T3_DIR  output directory (must exist; also pass -snapshot_directory)
--   T3_T    emulated seconds to start at
--
-- The subscriptions are globals: a chunk-local one is collected and stops
-- (LESSONS_LEARNED, "[GX] A Lua subscription must be held in a GLOBAL").
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local dir = os.getenv("T3_DIR")
local t0 = tonumber(os.getenv("T3_T"))
local n = 0
local bank = 0
local function dump(name, a0, len)
  local f = assert(io.open(string.format("%s/%s", dir, name), "wb"))
  for a = a0, a0 + len - 1 do f:write(string.char(sp:read_u8(a))) end
  f:close()
end
gx_psac_bank = sp:install_write_tap(0xe40000, 0xe40003, "bk", function(o,d,mk) if mk & 0xff000000 ~= 0 then bank = (d >> 24) & 0xff end end)
gx_psac_ack = sp:install_write_tap(0xd4c01c, 0xd4c01f, "ack", function(o,d,mk)
  if m.time.seconds < t0 or n >= 4 then return end
  local p = string.format("d%d_", n)
  dump(p .. "ctrl.bin", 0xe00000, 0x20)
  dump(p .. "line.bin", 0xe60000, 0x1000)
  dump(p .. "palm.bin", 0xe80000, 0x4000)
  dump(p .. "pals.bin", 0xea0000, 0x4000)
  dump(p .. "k55.bin", 0xd50000, 0x100)
  local f = assert(io.open(string.format("%s/%sinfo.txt", dir, p), "w"))
  f:write(string.format("bank %02x sync %08x time %s\n", bank, sp:read_u32(0xec0000), tostring(m.time)))
  f:close()
  for tag, scr in pairs(m.screens) do scr:snapshot(string.format("%s%s.png", p, tag:gsub(":",""))) end
  n = n + 1
  if n == 4 then m:exit() end
end)
