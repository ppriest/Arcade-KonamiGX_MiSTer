-- SPDX-License-Identifier: GPL-3.0-or-later
-- Type 1 (racinfrc, opengolf): reads and writes per region of the Type 1
-- map, per frame range, and the first PCs reading each. Env T1_FRAMES (default
-- 1800), T1_OUT (default t1_access.txt).
local frames = tonumber(os.getenv("T1_FRAMES") or "1800")
local out = os.getenv("T1_OUT") or "t1_access.txt"
local cpu = manager.machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
local R = {
  { "adc_w",   0xdda000, 0xddafff }, { "adc_r",  0xddc000, 0xddcfff },
  { "lamp",    0xdde000, 0xdde003 }, { "k936",   0xe00000, 0xe0001f },
  { "psac4",   0xe20000, 0xe2000f }, { "bank",   0xe40000, 0xe40003 },
  { "linectl", 0xe80000, 0xe81fff }, { "psacram",0xec0000, 0xedffff },
  { "hrom",    0xf00000, 0xf3ffff }, { "crom",   0xf40000, 0xf7ffff },
  { "lram",    0xf80000, 0xf80fff }, { "lookup", 0xfc0000, 0xfc00ff },
  { "lan",     0xdc0000, 0xdc1fff }, { "lanreg", 0xdd0000, 0xdd00ff },
  { "pal",     0xd90000, 0xd97fff },
}
local st = {}
t1_taps = {}  -- global: a tap is removed when its handle is collected
local taps = t1_taps
local frame = 0
for _, r in ipairs(R) do
  local s = { rd = 0, wr = 0, rdpc = {}, nrdpc = 0, frd = nil, lrd = nil }
  st[r[1]] = s
  taps[#taps + 1] = sp:install_read_tap(r[2], r[3], "t1r_" .. r[1], function(o, d, m)
    s.rd = s.rd + 1
    s.frd = s.frd or frame; s.lrd = frame
    local pc = cpu.state["PC"].value
    if not s.rdpc[pc] and s.nrdpc < 8 then s.rdpc[pc] = string.format("%06x@%06x f%d", pc, o, frame); s.nrdpc = s.nrdpc + 1 end
  end)
  taps[#taps + 1] = sp:install_write_tap(r[2], r[3], "t1w_" .. r[1], function(o, d, m)
    s.wr = s.wr + 1
  end)
end
taps[#taps + 1] = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == frames then
    local f = io.open(out, "w")
    for _, r in ipairs(R) do
      local s = st[r[1]]
      f:write(string.format("%-8s rd %8d wr %8d  reads frames %s-%s\n", r[1], s.rd, s.wr, tostring(s.frd), tostring(s.lrd)))
      for _, v in pairs(s.rdpc) do f:write("    " .. v .. "\n") end
    end
    f:close()
    manager.machine:exit()
  end
end)
