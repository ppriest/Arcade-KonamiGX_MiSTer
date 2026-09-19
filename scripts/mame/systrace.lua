-- The main CPU's view of the machine, frame by frame, as ground truth for the
-- RTL main board's own trace. Driven by scripts/mame_sys_trace.py.
--
--   GX_OUT     directory to write into (must exist)
--   GX_TAG     filename prefix
--   GX_FRAMES  how many frames to log before stopping
--
-- What is logged, and why only this:
--
--   every WRITE, anywhere           the machine state the CPU produces
--   every READ in 0xd00000-0xdfffff the I/O and video reads: inputs, status,
--                                   the K056800 mailbox, VRAM/palette reads
--   READS of 0x60-0x7f              the autovectors: a read of one marks an
--                                   interrupt taken (the BIOS also runs code and
--                                   checksums 0x000-0x3ff, so no wider)
--   "# frame N"                     at each frame
--
-- The last column is the interrupt mask (SR bits 8-10) when the access was
-- made: scripts/check_gx_main.py compares the main program and each
-- interrupt level as separate streams, because where an interrupt lands in
-- the main program's stream depends on each CPU's speed.
--
-- ROM and work-RAM reads are left out: they are the bulk of the traffic, the
-- ROM is proven (Phase 0) and work-RAM reads return what was written.
--
-- The subscriptions are GLOBAL on purpose (LESSONS_LEARNED, "[GX] A Lua
-- subscription must be held in a GLOBAL"): chunk-locals are collected after
-- the chunk returns and the taps silently stop.

local OUT    = os.getenv("GX_OUT") or "."
local TAG    = os.getenv("GX_TAG") or "trace"
local FRAMES = tonumber(os.getenv("GX_FRAMES") or "60")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local sr   = cpu.state["SR"]

local f = assert(io.open(string.format("%s/%s_sys.trace", OUT, TAG), "w"))
f:write("# main CPU: all writes, reads of 0xd00000-0xdfffff and of the vector table\n")
f:write("# seq\trw\taddr\tmask\tdata\tipl\n")

local n, done, first_err = 0, false, nil

local function stop()
    if done then return end
    done = true
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:write(string.format("# %d accesses logged\n", n))
    f:close()
    print(string.format("SYSTRACE %d accesses to %s/%s_sys.trace", n, OUT, TAG))
    mach:exit()
end

local function log(rw, offset, data, mask)
    n = n + 1
    f:write(string.format("%d\t%s\t%06X\t%08X\t%08X\t%d\n", n, rw, offset & 0xFFFFFF,
                          mask & 0xFFFFFFFF, data & 0xFFFFFFFF, (sr.value >> 8) & 7))
end

local function guard(fn)
    return function(offset, data, mask)
        if not done then
            local ok, err = pcall(fn, offset, data, mask)
            if not ok and not first_err then first_err = tostring(err) end
        end
        return data
    end
end

gx_subs = {}
gx_subs[#gx_subs + 1] = prog:install_write_tap(0x000000, 0xffffff, "gx_sys_w",
    guard(function(offset, data, mask) log("w", offset, data, mask) end))
gx_subs[#gx_subs + 1] = prog:install_read_tap(0xd00000, 0xdfffff, "gx_sys_r",
    guard(function(offset, data, mask) log("r", offset, data, mask) end))
gx_subs[#gx_subs + 1] = prog:install_read_tap(0x000060, 0x00007f, "gx_sys_vec",
    guard(function(offset, data, mask) log("r", offset, data, mask) end))

local frame = 0
gx_subs[#gx_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    frame = frame + 1
    f:write(string.format("# frame %d\n", frame))
    if frame >= FRAMES then stop() end
end)
