-- The sound 68000's bus, for comparison with the board's trace
-- (rtl/gx_trace.sv, scripts/snd_trace.py) and the bench's (+SND_TRACE).
-- Driven by scripts/snd_trace.py --mame.
--
--   GX_OUT      file to write
--   GX_SECONDS  how long to log
--
-- One line per access: <time_us> <R|W> <addr> <mask> <data>, the sound
-- CPU's whole space. Opcode fetches come through the read tap too. The
-- 68000's prefetch order and MAME's need not match a real 68000's, so
-- the comparison is of writes and of reads outside ROM and RAM.
--
-- The subscriptions are GLOBAL on purpose (LESSONS_LEARNED).

local OUT = os.getenv("GX_OUT") or "sndtrace.txt"
local SECONDS = tonumber(os.getenv("GX_SECONDS") or "10")
local m = manager.machine
local scr = m.screens[":screen"]
local snd = m.devices[":soundcpu"].spaces["program"]

subs = {}
local f = assert(io.open(OUT, "w"))
local n = 0

subs[#subs + 1] = snd:install_write_tap(0x000000, 0xffffff, "st_w",
    function(offset, data, mask)
        n = n + 1
        f:write(string.format("%d W %06x %04x %04x\n",
            math.floor(m.time:as_double() * 1e6), offset & 0xffffff, mask & 0xffff, data & 0xffff))
    end)
subs[#subs + 1] = snd:install_read_tap(0x000000, 0xffffff, "st_r",
    function(offset, data, mask)
        n = n + 1
        f:write(string.format("%d R %06x %04x %04x\n",
            math.floor(m.time:as_double() * 1e6), offset & 0xffffff, mask & 0xffff, data & 0xffff))
    end)

local done = false
subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    if done or scr:frame_number() < SECONDS * 60 then return end
    done = true
    f:close()
    print(string.format("GX_SNDTRACE_OK %d", n))
    m:exit()
end)
