-- Capture Konami GX video state from MAME at a chosen frame.
-- Driven by scripts/mame_capture.py; see docs/WORKFLOW.md section 9.
--
-- WHAT THIS CAPTURES, AND WHY IN TWO DIFFERENT WAYS
--
-- Readable RAM (work, sprite, palette) is read through the CPU's own address
-- space, because that returns what the CPU would read -- device handlers and
-- umask included -- which is the thing the RTL has to match.
--
-- The video REGISTERS cannot be read that way at all. On System GX the
-- K056832, K053246/K055673, K055555 and K054338 are mapped write-only
-- (gx_base_memmap has no read handler for d40000, d48000, d4a010, d50000 or
-- d80000), and MAME keeps their state inside the devices. So they are
-- reconstructed from a write tap installed before the machine runs: every
-- write to those ranges is recorded, and the last value written to each
-- address is the register state at the captured frame.
--
-- The tilemap VRAM has the same problem for a different reason: the CPU sees
-- only an 8 KB window at 0xda0000 into 16 banked pages, so a read of the
-- window captures one page and nothing else. It is reconstructed from writes
-- too, tracked per (bank, offset).
--
-- A write log cannot see state a device writes to itself. The sprite DMA
-- (konamigx_objdma) is a memcpy inside MAME, not a CPU write, so the sprite
-- shadow buffer it fills is NOT reconstructable here -- what is captured is
-- the sprite RAM the CPU wrote, read back directly, which is the input to
-- that copy. docs/ROADMAP.md notes the copy is a copy and not a bank swap.

local OUT   = os.getenv("GX_OUT")   or "capture"
local FRAME = tonumber(os.getenv("GX_FRAME") or "1200")
local m     = manager.machine

local function mkdir(p) os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') end
mkdir(OUT)

-- An error inside a Lua callback is SILENT: MAME keeps running, the callback
-- stops, and the run exits 0 having produced nothing. That cost one run here
-- already. Everything below goes through guard(), which writes the failure
-- where the Python side can read it back (WORKFLOW section 9).
local function guard(what, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            local f = io.open(OUT .. "/ERROR.txt", "a")
            if f then f:write(what, ": ", tostring(err), "\n"); f:close() end
            print("GX_CAPTURE_ERROR " .. what .. ": " .. tostring(err))
            error(err)
        end
        return ok
    end
end

local function wr(name, bytes)
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(bytes)
    f:close()
end

-- ---------------------------------------------------------------- write taps
-- Keep every subscription in a table that outlives this script. Dropping the
-- return value lets the GC reclaim the tap and it SILENTLY stops firing --
-- a Fuuki finding, recorded in LESSONS_LEARNED.
--
-- `subs` IS GLOBAL ON PURPOSE. A local is not enough, and that is a sharper
-- version of the same rule than the one carried over: an autoboot script's
-- chunk-local variables become collectable as soon as the chunk returns, so
-- the taps and the notifier survive roughly a hundred frames and then stop,
-- with no error and exit status 0. Measured here: with `local subs`, the
-- frame notifier fired exactly 100 times and never again; made global, it ran
-- to 400 and beyond. Do not add `local`.
subs = {}

local regs = {}     -- regs[range_name][offset] = last byte written
local vram = {}     -- vram[bank][offset]       = last byte written
local RANGES = {
    k056832  = { 0xd40000, 0xd4003f },
    tilebank = { 0xd44000, 0xd4400f },
    k053246  = { 0xd48000, 0xd48007 },
    k055673  = { 0xd4a010, 0xd4a01f },
    k053252  = { 0xd4c000, 0xd4c01f },
    k055555  = { 0xd50000, 0xd500ff },
    k054338  = { 0xd80000, 0xd8001f },
    wrport   = { 0xd56000, 0xd58003 },
}

local sp = m.devices[":maincpu"].spaces["program"]

-- The 68EC020 bus is 32 bits; a tap reports the data and the mask actually
-- driven, so split into bytes rather than assuming a width.
local function note(tbl, base, addr, data, mask)
    for b = 0, 3 do
        local sh = (3 - b) * 8            -- big-endian: byte 0 is the MSB
        if (mask >> sh) & 0xff ~= 0 then
            tbl[(addr - base) + b] = (data >> sh) & 0xff
        end
    end
end

for name, r in pairs(RANGES) do
    regs[name] = {}
    subs[#subs + 1] = sp:install_write_tap(r[1], r[2], "gx_" .. name,
        guard("tap_" .. name, function(offset, data, mask)
            note(regs[name], r[1], offset, data, mask)
        end))
end

-- Tilemap VRAM: which 8 KB page the window shows is chosen by a K056832
-- register. MAME's k056832 device decodes it internally; what is observable
-- from here is the write to d40033 that selects it, so track that byte and
-- bucket VRAM writes by it.
local vbank = 0
subs[#subs + 1] = sp:install_write_tap(0xd40030, 0xd40033, "gx_vbank",
    guard("tap_vbank", function(offset, data, mask)
        for b = 0, 3 do
            local sh = (3 - b) * 8
            if (mask >> sh) & 0xff ~= 0 and (offset + b) == 0xd40033 then
                vbank = (data >> sh) & 0xff
            end
        end
    end))

subs[#subs + 1] = sp:install_write_tap(0xda0000, 0xda3fff, "gx_vram",
    guard("tap_vram", function(offset, data, mask)
        vram[vbank] = vram[vbank] or {}
        note(vram[vbank], 0xda0000, offset, data, mask)
    end))

-- --------------------------------------------------------------------- dump
local function read_block(base, len)
    local t = {}
    for a = 0, len - 4, 4 do
        local v = sp:read_u32(base + a)
        t[#t + 1] = string.char((v >> 24) & 0xff, (v >> 16) & 0xff,
                                (v >> 8) & 0xff, v & 0xff)
    end
    return table.concat(t)
end

local function dump_sparse(name, tbl, size)
    local t = {}
    for i = 0, size - 1 do t[i + 1] = string.char(tbl[i] or 0) end
    wr(name, table.concat(t))
end

local done = false
subs[#subs + 1] = emu.add_machine_frame_notifier(guard("frame", function()
    if done then return end
    local scr = m.screens[":screen"]
    if scr:frame_number() < FRAME then return end
    done = true

    -- readable RAM, through the CPU's own view
    wr("workram.bin",  read_block(0xc00000, 0x20000))
    wr("spriteram.bin", read_block(0xd20000, 0x4000))
    wr("palette.bin",  read_block(0xd90000, 0x8000))

    -- write-only register files, reconstructed
    for name, r in pairs(RANGES) do
        dump_sparse("reg_" .. name .. ".bin", regs[name], r[2] - r[1] + 1)
    end

    -- banked tilemap VRAM, reconstructed per page
    local banks = {}
    for bank, _ in pairs(vram) do banks[#banks + 1] = bank end
    table.sort(banks)
    local man = {}
    for _, bank in ipairs(banks) do
        dump_sparse(string.format("vram_bank%02x.bin", bank), vram[bank], 0x4000)
        man[#man + 1] = string.format("%02x", bank)
    end

    scr:snapshot(OUT .. "/reference.png")

    local f = assert(io.open(OUT .. "/manifest.txt", "w"))
    f:write("set ", m.system.name, "\n")
    f:write("mame ", emu.app_version(), "\n")
    f:write("frame ", tostring(scr:frame_number()), "\n")
    f:write("screen ", tostring(scr.width), "x", tostring(scr.height), "\n")
    f:write("vram_banks_written ", table.concat(man, ","), "\n")
    f:close()

    print("GX_CAPTURE_OK " .. OUT)
    m:exit()
end))
