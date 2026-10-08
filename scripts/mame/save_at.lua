-- SPDX-License-Identifier: GPL-3.0-or-later
-- Saves a state at an emulated time, for scripts/gxss.py from-mame, with
-- what MAME's state does not hold beside it (GX_SAVE_SIDE, JSON):
--   k053252   the 16 registers as last written (MAME saves none)
--   t3_bank   the Type 3/4 bank register (type3_bank_w), as last written
--   t3_frame  the frame flag: 1 when 0xec0000 reads 0 (type3_sync_r)
--
--   GX_SAVE_AT     seconds of emulated time
--   GX_SAVE_NAME   the state's name (machine:save, under -state_directory)
--   GX_SAVE_SIDE   the JSON's path
--   GX_INPUTS      optional presses, "25:Coin 1,28:1 Player Start": the
--                  field held from that second for 0.3 s
local m = manager.machine
local at = tonumber(os.getenv("GX_SAVE_AT"))
local name = os.getenv("GX_SAVE_NAME")
local side = os.getenv("GX_SAVE_SIDE")
local sp = m.devices[":maincpu"].spaces["program"]

local function field(n)
  for _, port in pairs(m.ioport.ports) do
    for fn, f in pairs(port.fields) do if fn == n then return f end end
  end
  error("no input " .. n)
end
local presses = {}
for t, n in string.gmatch(os.getenv("GX_INPUTS") or "", "([%d%.]+):([^,]+)") do
  presses[#presses + 1] = { t = tonumber(t), f = field(n), st = 0 }
end

local crtc, bank = {}, nil
for i = 0, 15 do crtc[i] = 0 end
-- umask32 ff00ff00: register k is bits 15:8 of the word at 0xd4c000 + 2k
gx_sa_crtc = sp:install_write_tap(0xd4c000, 0xd4c01f, "gx_crtc", function(o, d, mk)
  local k = (o - 0xd4c000) // 2
  if mk & 0xff000000 ~= 0 then crtc[k] = (d >> 24) & 0xff end
  if mk & 0x0000ff00 ~= 0 then crtc[k + 1] = (d >> 8) & 0xff end
end)
local t3 = m.devices[":k053936_0"] ~= nil or m.system.name:find("^soccerss") ~= nil
if t3 then
  gx_sa_bank = sp:install_write_tap(0xe40000, 0xe40003, "gx_t3bank", function(o, d, mk)
    if o == 0xe40000 and mk & 0xff000000 ~= 0 then bank = (d >> 24) & 0xff end
  end)
end

local state = 0
gx_sa_per = emu.register_periodic(function()
  local t = m.time:as_double()
  for _, p in ipairs(presses) do
    if p.st == 0 and t >= p.t then p.f:set_value(1); p.st = 1
    elseif p.st == 1 and t >= p.t + 0.3 then p.f:clear_value(); p.st = 2 end
  end
  if state == 0 and t >= at then
    local h = assert(io.open(side, "w"))
    local r = {}
    for i = 0, 15 do r[#r + 1] = tostring(crtc[i]) end
    h:write('{"time": ' .. string.format("%.6f", t) .. ', "k053252": [' .. table.concat(r, ", ") .. "]")
    if t3 then
      local sync = sp:read_u32(0xec0000)
      h:write(', "t3_bank": ' .. tostring(bank or 0) .. ', "t3_frame": ' .. (sync == 0 and "1" or "0"))
    end
    h:write("}\n")
    h:close()
    m:save(name)
    state = 1
  elseif state == 1 and t >= at + 0.05 then
    m:exit()
  end
end)
