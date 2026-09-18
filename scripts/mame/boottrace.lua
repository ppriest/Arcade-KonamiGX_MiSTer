-- Log the first N main-CPU bus accesses of a boot, as ground truth for the
-- RTL's own boot trace to be diffed against. Phase 0 exit criterion 2.
--
-- Driven by scripts/mame_boot_trace.py. Parameters arrive as environment
-- variables:
--
--   GX_OUT      directory to write into (must already exist)
--   GX_TAG      prefix for the output filename (normally the set name)
--   GX_TRACE_N  how many accesses to log before stopping
--
-- Ported from the Jaleco MS32 core's scripts/mame/boottrace.lua, itself from
-- Seta's. What changed for GX: the address is 24 bits. MAME constructs the
-- M68EC020 as `m68000_musashi_device(..., M68EC020, 32, 24)` -- a 32-bit data
-- bus and a 24-bit ADDRESS bus -- so the tap covers 0x000000-0xffffff and
-- logs six hex digits. MS32's V70 needed 32 bits of address; Seta's 68000
-- needed 24 and 16 bits of data. GX needs 24 and 32.
--
-- WHY A READ TAP RATHER THAN THE DEBUGGER'S `trace`
--
-- MAME's `trace` emits one line per INSTRUCTION START. The RTL testbench sees
-- every bus ACCESS -- operand reads, stack pushes, table lookups. A read tap
-- on the program space records the accesses directly, so there is nothing to
-- reconstruct. It needs no debugger, which this machine's mame.ini would
-- otherwise open (it has `debug 1`).
--
-- What it does NOT capture: the distinction between an opcode fetch and a
-- data read (the tap gives no function code), nor the WIDTH of each CPU
-- access -- `mask` says which lanes were asked for. Both are logged; the RTL
-- bench should match the ordered ADDRESS sequence and use mask/data as a
-- check, not as the key.
--
-- TG68K.C prefetches, so the RTL will read ROM words MAME never touches and
-- in a different order. That is why the comparison is a subsequence match
-- with duplicates collapsed (LESSONS_LEARNED, "[Seta] Two cores that both
-- boot correctly still fetch different words").

local OUT = os.getenv("GX_OUT") or "."
local TAG = os.getenv("GX_TAG") or "trace"
local N   = tonumber(os.getenv("GX_TRACE_N") or "512")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]

local f = assert(io.open(string.format("%s/%s_boot.trace", OUT, TAG), "w"))
f:write("# main-CPU bus accesses from reset, in order.\n")
f:write("# seq\trw\taddr\tmask\tdata\n")

local n, done = 0, false
local hits, logged, first_err = 0, 0, nil

local function stop()
    if done then return end
    done = true
    f:write(string.format("# %d accesses seen, %d logged\n", hits, logged))
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:close()
    print(string.format("TRACE  %d accesses logged to %s/%s_boot.trace",
                        logged, OUT, TAG))
    mach:exit()
end

-- Every callback is wrapped and counted. An error inside a tap is SWALLOWED by
-- MAME -- on the Seta core that produced 459 tap hits and an empty log with no
-- diagnostic anywhere. A hits count beside a logged count is what makes that
-- visible instead of silent.
local function record(rw)
    return function(offset, data, mask)
        hits = hits + 1
        if not done then
            local ok, err = pcall(function()
                n = n + 1
                f:write(string.format("%d\t%s\t%06X\t%08X\t%08X\n", n, rw,
                                      offset & 0xFFFFFF, mask & 0xFFFFFFFF,
                                      data & 0xFFFFFFFF))
                logged = logged + 1
            end)
            if not ok and not first_err then first_err = tostring(err) end
            if n >= N then stop() end
        end
        return data
    end
end

-- GLOBAL, not local. An autoboot script's chunk-locals are collectable the
-- moment the chunk returns, and a collected tap silently stops firing
-- (LESSONS_LEARNED, "[GX] A Lua subscription must be held in a GLOBAL").
-- MS32's version of this file already used _G for exactly this reason.
_G.__gx_trace_taps = {
    prog:install_read_tap(0x000000, 0xffffff, "rd", record("r")),
    prog:install_write_tap(0x000000, 0xffffff, "wr", record("w")),
}

-- A backstop, so a game that somehow makes fewer than N accesses still writes
-- its file rather than leaving an empty one behind when MAME's own
-- -seconds_to_run kills the run.
_G.__gx_trace_notifier = emu.add_machine_frame_notifier(function()
    if mach.screens[":screen"]:frame_number() >= 600 then stop() end
end)
