-- Record MAME's emulated time at two points in a game's program.
-- Phase 0 exit criterion 3 (CPI). Driven by scripts/cpi_compare.py.
--
-- WHY WRITE-COUNT MARKS. TG68K.C and MAME reach the first program-ROM read at
-- the same access number (884,944 for daiskiss), but after that the two cores'
-- access counts drift -- TG68K.C prefetches -- so an access number is not a
-- common point inside the program. A WRITE is: sim/gx_boot_tb matches MAME
-- write-for-write, so "the n-th write to address X with lanes M" is the same
-- program event on both sides. A byte write is best, because it is a single
-- access on both buses and cannot be split in two.
--
-- And the marks are INSIDE the program, not in the BIOS. The BIOS spends its
-- first 884,944 accesses checksumming ROM in a tight loop, and LESSONS_LEARNED
-- records what that is worth: "[MS32] A CPI measured on the power-on RAM test
-- is a CPI of the RAM test".
--
-- PRECISION. This MAME build exposes no per-CPU cycle counter to Lua
-- (total_cycles is nil), so the time is machine.time read inside the tap. That
-- is the start of the scheduler's current timeslice, not the CPU's exact local
-- time, so each mark can be EARLY by up to one quantum. konamigx.cpp sets
-- set_maximum_quantum(attotime::from_hz(6000)): at most 166.7 us, 4,000 cycles
-- at 24 MHz, per mark.

local OUT   = os.getenv("GX_OUT") or "mark.txt"
local ADDR  = tonumber(os.getenv("GX_MARKADDR") or "0xD56000")
local MASK  = tonumber(os.getenv("GX_MARKMASK") or "0xFF000000")
local A     = tonumber(os.getenv("GX_MARKA") or "31")
local B     = tonumber(os.getenv("GX_MARKB") or "49")
local m     = manager.machine
local prog  = m.devices[":maincpu"].spaces["program"]

local n, f = 0, assert(io.open(OUT, "w"))
local function hit(offset, data, mask)
    if (offset & 0xFFFFFC) ~= ADDR or mask ~= MASK then return data end
    n = n + 1
    if n == A or n == B then
        f:write(string.format("mark write=%d seconds=%.9f\n", n, m.time:as_double()))
        f:flush()
        if n == B then
            f:close()
            print("GX_MARK_OK")
            m:exit()
        end
    end
    return data
end

-- GLOBAL: a chunk-local subscription is collected when the chunk returns.
_G.__gx_mark = { prog:install_write_tap(ADDR, ADDR + 3, "mw", hit) }
