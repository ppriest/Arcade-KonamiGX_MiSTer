-- Log every sound-CPU access to the TMS57002 host interface, in order.
-- Driven by scripts/dasp_log.py. The log is the reference for the DSP model
-- (scripts/tms57002.py) and the HDL (rtl/sound/gx_tms57002.sv).
--
--   0x300001  data byte           W data_w, R data_r
--   0x500000  status (read)       {dready, pc0, empty} in bits 2..0
--   0x500001  control (write)     pload_w(d&4), cload_w(d&8), reset=!(d&0x10)
--
-- One line per access:  <time_us> <frame> <kind> <value hex>
--   kind: C control write, W data write, R data read, S status read

local OUT = os.getenv("GX_OUT") or "dasp_log.txt"
local SECONDS = tonumber(os.getenv("GX_SECONDS") or "10")
local m = manager.machine
local scr = m.screens[":screen"]
local snd = m.devices[":soundcpu"].spaces["program"]

subs = {}
local f = assert(io.open(OUT, "w"))

local function log(kind, v)
    f:write(string.format("%d %d %s %02x\n",
        math.floor(m.time:as_double() * 1e6), scr:frame_number(), kind, v))
end

subs[#subs + 1] = snd:install_write_tap(0x500000, 0x500001, "dl_ctrl",
    function(offset, data, mask)
        if mask & 0x00ff ~= 0 then log("C", data & 0xff) end
    end)
subs[#subs + 1] = snd:install_read_tap(0x500000, 0x500001, "dl_stat",
    function(offset, data, mask)
        log("S", data & 0xff)
    end)
subs[#subs + 1] = snd:install_write_tap(0x300000, 0x300001, "dl_dw",
    function(offset, data, mask)
        if mask & 0x00ff ~= 0 then log("W", data & 0xff) end
    end)
subs[#subs + 1] = snd:install_read_tap(0x300000, 0x300001, "dl_dr",
    function(offset, data, mask)
        if mask & 0x00ff ~= 0 then log("R", data & 0xff) end
    end)

local done = false
subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    if done or scr:frame_number() < SECONDS * 60 then return end
    done = true
    f:close()
    print("GX_DASPLOG_OK")
    m:exit()
end)
