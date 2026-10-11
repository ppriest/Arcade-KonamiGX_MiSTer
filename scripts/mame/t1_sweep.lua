-- SPDX-License-Identifier: GPL-3.0-or-later
-- Type 1 video-write sweep (references/video_write_sweep.md): every write to
-- the terrain's state, histogrammed by the raster line it lands on, per
-- phase (attract, then play after a coin and start), and the frame of the
-- last write of each. Env T1_FRAMES (default 3600), T1_COIN (frame of the
-- coin; start follows 60 frames later; the gas is held from then), T1_OUT.
local frames = tonumber(os.getenv("T1_FRAMES") or "3600")
local coin_at = tonumber(os.getenv("T1_COIN") or "1500")
local out = os.getenv("T1_OUT") or "t1_sweep.txt"
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local R = {
  { "k936",    0xe00000, 0xe0001f }, { "psac4",  0xe20000, 0xe2000f },
  { "bank",    0xe40000, 0xe40003 }, { "linectl",0xe80000, 0xe81fff },
  { "psacram", 0xec0000, 0xedffff }, { "lram",   0xf80000, 0xf80fff },
  { "lookup",  0xfc0000, 0xfc00ff }, { "pal",    0xd90000, 0xd97fff },
  { "k056832", 0xd80000, 0xd8003f }, { "objram", 0xd20000, 0xd23fff },
}
local frame = 0
local t_vbl, scan = 0, 0
local function phase() return frame < coin_at and 1 or 2 end
local H = {}          -- H[name][phase][line] = count
local F = {}          -- F[name][phase] = frames with a write
for _, r in ipairs(R) do
  H[r[1]] = { {}, {} }; F[r[1]] = { 0, 0 }
end
local wrote = {}
t1s_taps = {}
for _, r in ipairs(R) do
  local name = r[1]
  t1s_taps[#t1s_taps + 1] = sp:install_write_tap(r[2], r[3], "t1s_" .. name, function(o, d, mk)
    local p = phase()
    -- the line since vblank began (this MAME's Lua has no vpos): the
    -- frame notifier runs at the screen update, at vblank start
    local v = math.floor((m.time:as_double() - t_vbl) / scan)
    local h = H[name][p]
    h[v] = (h[v] or 0) + 1
    wrote[name] = true
  end)
end
-- fields by name, whichever port holds them
local function press(field, on)
  for _, p in pairs(m.ioport.ports) do
    local f = p.fields[field]
    if f then f:set_value(on and 1 or 0) return end
  end
end
t1s_taps[#t1s_taps + 1] = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local sp_ = scr.scan_period
  t_vbl, scan = m.time:as_double(), type(sp_) == "number" and sp_ or sp_:as_double()
  for name in pairs(wrote) do F[name][phase()] = F[name][phase()] + 1 end
  wrote = {}
  press("Coin 1", frame >= coin_at and frame < coin_at + 8)
  press("1 Player Start", frame >= coin_at + 60 and frame < coin_at + 68)
  -- T1_GAS: hold the pedal (AN1, 0x90 = full) from the start onwards
  if os.getenv("T1_GAS") and frame >= coin_at + 60 then
    for _, p in pairs(m.ioport.ports) do
      local f = p.fields["Gas Pedal"]
      if f then f:set_value(0x90) end
    end
  end
  -- T1_SHOTS: every n frames, a picture into T1_OUT's directory
  local every = tonumber(os.getenv("T1_SHOTS") or "0")
  if every > 0 and frame % every == 0 then
    scr:snapshot(out:gsub("[^/]*$", "") .. string.format("f%05d.png", frame))
  end
  if frame == frames then
    local f = io.open(out, "w")
    f:write(string.format("# frames %d, coin %d; screen %d lines\n", frames, coin_at, scr.height))
    for _, r in ipairs(R) do
      for p = 1, 2 do
        local h, tot = H[r[1]][p], 0
        local buckets = {}
        for v, n in pairs(h) do tot = tot + n; local b = v // 8; buckets[b] = (buckets[b] or 0) + n end
        f:write(string.format("%s %s: %d writes in %d frames;", r[1], p == 1 and "attract" or "play", tot, F[r[1]][p]))
        for b = 0, 50 do if buckets[b] then f:write(string.format(" %d:%d", b * 8, buckets[b])) end end
        f:write("\n")
      end
    end
    f:close()
    m:exit()
  end
end)
