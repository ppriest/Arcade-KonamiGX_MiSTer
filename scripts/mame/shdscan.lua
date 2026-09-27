-- Find frames with shadows that MAME 5c75784 defers (SHD PRI SEL conditions
-- 1 and 2, gx_draw_deferred_shadows): a sprite whose shadow code is enabled
-- (a K054338 delta outside +/-7) and whose condition is 1 or 2.
--
--   GX_OUT=path GX_FRAMES=n mame <set> -autoboot_script shdscan.lua
--
-- One line per such frame: <frame> <sel> <deferred objects> <codes>.
-- The K055555, K054338 and K053246 registers are write-only on this board;
-- they are followed through write taps, as scripts/mame/capture.lua does.
-- Not modelled here: a callback's FULLSHADOW (condition 3), primode -1.

local OUT = os.getenv("GX_OUT") or "shdscan.txt"
local FRAMES = tonumber(os.getenv("GX_FRAMES") or "20000")
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local scr = m.screens[":screen"]
local f = assert(io.open(OUT, "w"))

subs = {}
local k55, k338, k46 = {}, {}, {}
for i = 0, 63 do k55[i] = 0 end
for i = 0, 15 do k338[i] = 0 end
for i = 0, 7 do k46[i] = 0 end

-- 32-bit bus: each tap sees a dword; its halves are the even and odd words
local function halves(offset, data, mask, fn)
    if (mask >> 16) & 0xffff ~= 0 then fn(offset, (data >> 16) & 0xffff, (mask >> 16) & 0xffff) end
    if mask & 0xffff ~= 0 then fn(offset + 2, data & 0xffff, mask & 0xffff) end
end

subs[#subs + 1] = sp:install_write_tap(0xd50000, 0xd500ff, "scan_k55", function(offset, data, mask)
    halves(offset, data, mask, function(a, d, mk)
        if mk & 0xff00 ~= 0 then k55[((a - 0xd50000) >> 1) & 63] = (d >> 8) & 0xff end
    end)
end)
subs[#subs + 1] = sp:install_write_tap(0xd80000, 0xd8001f, "scan_k338", function(offset, data, mask)
    halves(offset, data, mask, function(a, d, mk)
        local i = ((a - 0xd80000) >> 1) & 15
        k338[i] = (k338[i] & ~mk) | (d & mk)
    end)
end)
subs[#subs + 1] = sp:install_write_tap(0xd48000, 0xd48007, "scan_k46", function(offset, data, mask)
    for b = 0, 3 do
        if (mask >> (24 - 8 * b)) & 0xff ~= 0 then
            k46[((offset - 0xd48000) + b) & 7] = (data >> (24 - 8 * b)) & 0xff
        end
    end
end)

local function sgn9(v) v = v & 0x1ff; if v >= 0x100 then return v - 0x200 end return v end

local hits = 0
subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    local fr = scr:frame_number()
    if fr > FRAMES then
        f:write(string.format("# %d frames, %d with deferred shadows\n", FRAMES, hits))
        f:close(); print("GX_SHDSCAN_OK"); m:exit(); return
    end
    local sel = k55[41]
    local on = {}
    for i = 0, 2 do
        on[i] = false
        for c = 0, 2 do
            local v = sgn9(k338[2 + 3 * i + c])
            if v < -7 or v > 7 then on[i] = true end
        end
    end
    local n, codes = 0, {}
    for x = 0, 255 do
        local base = 0xd20000 + x * 16
        if sp:read_u16(base) & 0x8000 ~= 0 then
            local k = sp:read_u16(base + 12)
            local shadow = (k >> 10) & 3
            local code = nil
            if shadow ~= 0 then
                if shadow ~= 1 or (k46[5] & 0x20) ~= 0 then code = shadow - 1 else code = 0 end
            end
            if code ~= nil and on[code] then
                local cond = (sel >> (2 * code)) & 3
                if cond == 1 or cond == 2 then n = n + 1; codes[code] = true end
            end
        end
    end
    if n > 0 then
        hits = hits + 1
        local cs = ""
        for c = 0, 2 do if codes[c] then cs = cs .. c end end
        f:write(string.format("%d %02x %d %s\n", fr, sel, n, cs)); f:flush()
    end
end)
