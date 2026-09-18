-- Does this set use the TMS57002 "DASP" effects DSP at all?
-- Phase 0 exit criterion 5 (docs/ROADMAP.md). Driven by scripts/dasp_survey.py.
--
-- The DSP is on the SOUND 68000's bus, not the main CPU's (konamigx.cpp,
-- gxsndmap):
--
--   0x500000  control word. tms57002_control_word_w() does
--               pload_w(data & 4); cload_w(data & 8);
--               RESET = (data & 0x10) ? CLEAR : ASSERT
--   0x300001  data byte, tms57002_device::data_w()
--
-- READ THE SENSE CAREFULLY: pload_w(state) CLEARS the program-load flag when
-- state is non-zero (tms57002.cpp, pload_w). So program load is ACTIVE while
-- control bit 2 is 0, and likewise coefficient load while bit 3 is 0. Counting
-- bytes "while bit 2 is set" would count exactly the wrong ones --
-- LESSONS_LEARNED, "Copy a driver's register expression including its
-- operators".
--
-- In program-load mode the DSP takes bytes in threes: the first triple is
-- st0, the second st1, and every one after that is one program word. The
-- "words" this script reports are (bytes / 3) - 2 per session.
--
-- THAT IS NOT A PROGRAM LENGTH, and the first survey showed why. The
-- TMS57002's program space is 256 words (tms57002.cpp, internal_pgm:
-- map(0x00, 0xff)), yet every set has sessions that decode to 339 "words" --
-- 1,023 bytes, more than a full program's 774. So those sessions carry more
-- than one program's worth, or the program counter wraps and overwrites, or
-- the stream is not what the simple triple model assumes. Which of those it
-- is has not been established. What IS established is the thing criterion 5
-- asks: whether the sound CPU drives the DSP into program-load mode and
-- streams to it at all.

local OUT = os.getenv("GX_OUT") or "dasp.txt"
local SECONDS = tonumber(os.getenv("GX_SECONDS") or "60")
local m = manager.machine

-- GLOBAL on purpose: a chunk-local table is collected when the autoboot chunk
-- returns and every callback silently stops (LESSONS_LEARNED, [GX] entry).
subs = {}

local ctrl         = 0xff       -- last control byte; power-on value unknown, so
                                -- start with load inactive and reset released
local ctrl_writes  = 0
local reset_rel    = 0          -- control writes with bit 4 set (DSP running)
local pload_bytes  = 0          -- data bytes written while PLOAD active
local cload_bytes  = 0          -- ... while CLOAD active
local plain_bytes  = 0          -- ... with neither active (audio data path)
local pload_entries = 0         -- times PLOAD went inactive -> active
-- One entry per program-load SESSION. The DSP resets its program counter at
-- the start of each (tms57002.cpp, pload_w: pc = 0), so the sessions are
-- separate uploads, not one long program -- and the game reloads it more than
-- once, so a single total over the run means nothing.
local sessions = {}
local first_frame, last_frame

local snd = m.devices[":soundcpu"].spaces["program"]
local scr = m.screens[":screen"]

local function frame() return scr:frame_number() end

subs[#subs + 1] = snd:install_write_tap(0x500000, 0x500001, "dasp_ctrl",
    function(offset, data, mask)
        -- a 16-bit word write; the control bits are the low byte
        if mask & 0x00ff == 0 then return end
        local v = data & 0xff
        local was_pload = (ctrl & 4) == 0
        local now_pload = (v & 4) == 0
        if now_pload and not was_pload then
            pload_entries = pload_entries + 1
            sessions[#sessions + 1] = 0
        end
        if v & 0x10 ~= 0 then reset_rel = reset_rel + 1 end
        ctrl = v
        ctrl_writes = ctrl_writes + 1
    end)

subs[#subs + 1] = snd:install_write_tap(0x300000, 0x300001, "dasp_data",
    function(offset, data, mask)
        if mask & 0x00ff == 0 then return end   -- byte lane 0x300001 only
        local f = frame()
        first_frame = first_frame or f
        last_frame = f
        if (ctrl & 4) == 0 then
            pload_bytes = pload_bytes + 1
            if #sessions > 0 then sessions[#sessions] = sessions[#sessions] + 1 end
        elseif (ctrl & 8) == 0 then
            cload_bytes = cload_bytes + 1
        else
            plain_bytes = plain_bytes + 1
        end
    end)

local done = false
subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    if done or frame() < SECONDS * 60 then return end
    done = true
    local f = assert(io.open(OUT, "w"))
    -- program words per session: bytes in triples, minus the st0 and st1
    -- triples that open every session
    local words = {}
    local lo, hi
    for _, b in ipairs(sessions) do
        local w = b >= 6 and (b // 3 - 2) or 0
        words[#words + 1] = tostring(w)
        lo = (lo == nil or w < lo) and w or lo
        hi = (hi == nil or w > hi) and w or hi
    end
    f:write(string.format(
        "set=%s frames=%d ctrl_writes=%d reset_released=%d pload_entries=%d " ..
        "pload_bytes=%d words_min=%s words_max=%s cload_bytes=%d data_bytes=%d " ..
        "first_frame=%s last_frame=%s\n",
        m.system.name, frame(), ctrl_writes, reset_rel, pload_entries,
        pload_bytes, tostring(lo), tostring(hi), cload_bytes, plain_bytes,
        tostring(first_frame), tostring(last_frame)))
    f:write("session_words=" .. table.concat(words, ",") .. "\n")
    f:close()
    print("GX_DASP_OK")
    m:exit()
end)
