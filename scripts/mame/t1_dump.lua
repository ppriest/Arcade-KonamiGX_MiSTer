-- SPDX-License-Identifier: GPL-3.0-or-later
-- Type 1 (racinfrc): the terrain's state at given vblanks, for
-- scripts/t1_psac4_model.py, with MAME's picture of that vblank.
--
-- MAME draws the terrain at vblank start (VIDEO_UPDATE_AFTER_VBLANK) from
-- the state then; the frame notifier runs just after that update, before the
-- CPU runs again, so what is read there is what was drawn. Except:
--   - the y origin, latched at vblank END from the 056540's register 0
--     (type1_vblank_w): rebuilt here from the register's writes, the value
--     before the previous vblank's end;
--   - the lookup SRAM, 16 banks of 128 bytes behind the bank register, of
--     which the CPU sees one: rebuilt from every write and the bank then.
--
--   T1_DIR    output directory (must exist)
--   T1_AT     frames to dump, comma-separated
--   T1_COIN   frame of a coin (start 60 frames later, the gas held after)
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local dir = os.getenv("T1_DIR")
local at, last = {}, 0
for v in string.gmatch(os.getenv("T1_AT") or "", "%d+") do at[tonumber(v)] = true; last = math.max(last, tonumber(v)) end
local coin_at = tonumber(os.getenv("T1_COIN") or "-1")
local golf = os.getenv("T1_GOLF") == "1"
local shown = golf and 224 or 255

local bank = 0
local lookup = {}
for i = 0, 0x7ff do lookup[i] = 0 end
local p4w = {}          -- { time, register 0 } per write
local p4r0 = 0
local k14w = {}         -- { time, K053936 register 14 } per write
local k14 = 0
local yo = { nil, nil } -- the latched origins, by phase
t1d_taps = {}
t1d_taps[1] = sp:install_write_tap(0xe40000, 0xe40003, "t1d_bank", function(o, d, mk)
  -- type1_bank_w is a u16 handler on the 32-bit bus: both halves land in it
  if mk & 0xffff0000 ~= 0 then bank = (bank & ~(mk >> 16)) | ((d >> 16) & (mk >> 16)) end
  if mk & 0x0000ffff ~= 0 then bank = (bank & ~mk) | (d & mk) end
  bank = bank & 0xffff
end)
t1d_taps[2] = sp:install_write_tap(0xfc0000, 0xfc00ff, "t1d_lk", function(o, d, mk)
  -- umask 0xff00ff00: a byte at offset (address - 0xfc0000) / 2 for each lane
  local base = ((o - 0xfc0000) // 4) * 2
  if mk & 0xff000000 ~= 0 then lookup[((bank >> 12) << 7) | (base & 0x7f)] = (d >> 24) & 0xff end
  if mk & 0x0000ff00 ~= 0 then lookup[((bank >> 12) << 7) | ((base + 1) & 0x7f)] = (d >> 8) & 0xff end
end)
t1d_taps[3] = sp:install_write_tap(0xe20000, 0xe20003, "t1d_p4", function(o, d, mk)
  p4r0 = (p4r0 & ~mk) | (d & mk)
  p4w[#p4w + 1] = { m.time:as_double(), p4r0 }
end)
-- the K053936's registers are 16-bit on the 32-bit bus: 14 is 0xe0001c's high half
t1d_taps[5] = sp:install_write_tap(0xe0001c, 0xe0001f, "t1d_k14", function(o, d, mk)
  if mk & 0xffff0000 ~= 0 then
    k14 = (k14 & ~(mk >> 16)) | ((d >> 16) & (mk >> 16))
    k14w[#k14w + 1] = { m.time:as_double(), k14 }
  end
end)
local function at_time(h, t)
  local v = nil
  for _, w in ipairs(h) do if w[1] <= t then v = w[2] end end
  return v
end

local function dump_share(name, file, words)
  local s = m.memory.shares[name]
  local f = assert(io.open(dir .. "/" .. file, "wb"))
  for i = 0, words - 1 do f:write(string.pack("<I4", s:read_u32(i * 4))) end
  f:close()
end
local function dump_space16(a0, n, file)
  local f = assert(io.open(dir .. "/" .. file, "wb"))
  for i = 0, n - 1 do f:write(string.pack("<I2", sp:read_u16(a0 + 2 * i))) end
  f:close()
end
local function press(field, v)
  for _, p in pairs(m.ioport.ports) do
    local f = p.fields[field]
    if f then f:set_value(v) return end
  end
end

local frame, t_prev = 0, nil
t1d_taps[4] = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local now = m.time:as_double()
  local sp_ = scr.scan_period
  local scan = type(sp_) == "number" and sp_ or sp_:as_double()
  if coin_at >= 0 then
    press("Coin 1", (frame >= coin_at and frame < coin_at + 8) and 1 or 0)
    press("1 Player Start", (frame >= coin_at + 60 and frame < coin_at + 68) and 1 or 0)
    if frame >= coin_at + 60 then press("Gas Pedal", 0x90) end
  end
  if t_prev then
    -- the previous vblank ended (screen height - shown) lines after it began:
    -- type1_vblank_w latched register 0 there, into the phase register 14 gave
    local t_end = t_prev + (scr.height - shown) * scan
    local v = at_time(p4w, t_end)
    if v then
      local ph = golf and ((at_time(k14w, t_end) or 0) >> 7 & 1) or 0
      yo[ph + 1] = (v >> 8) & 0xffff
    end
  end
  if at[frame] and t_prev then
    local p = string.format("%s/f%05d_", dir, frame)
    dump_share(":psacram", string.format("f%05d_psacram.bin", frame), 0x8000)
    dump_share(":type1_psac4_lram", string.format("f%05d_lram.bin", frame), 0x400)
    dump_share(":type1_psac4_ctrl", string.format("f%05d_p4.bin", frame), 4)
    dump_space16(0xe00000, 16, string.format("f%05d_k936.bin", frame))
    dump_space16(0xe80000, 0x1000, string.format("f%05d_linectl.bin", frame))
    -- the main palette, 0xd90000, as the 68020 reads it (big-endian longs)
    local f = assert(io.open(string.format("%s/f%05d_pal.bin", dir, frame), "wb"))
    for i = 0, 0x1fff do f:write(string.pack(">I4", sp:read_u32(0xd90000 + 4 * i))) end
    f:close()
    f = assert(io.open(p .. "lookup.bin", "wb"))
    for i = 0, 0x7ff do f:write(string.char(lookup[i])) end
    f:close()
    f = assert(io.open(p .. "meta.txt", "w"))
    local hx = function(v) return v and string.format("%04x", v) or "none" end
    f:write(string.format("bank %04x\nyorigin %s\nyorigin1 %s\ngolf %d\n", bank,
      hx(yo[1]), hx(yo[2]), golf and 1 or 0))
    f:close()
    scr:snapshot(p .. "ref.png")
  end
  -- the register's history: the last few writes are enough
  while #p4w > 16 do table.remove(p4w, 1) end
  while #k14w > 16 do table.remove(k14w, 1) end
  t_prev = now
  if frame >= last then m:exit() end
end)
