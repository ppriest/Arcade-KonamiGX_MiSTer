-- Probe what this MAME build's Lua API actually provides.
-- WORKFLOW section 9: probe rather than write against the online docs.
local out = assert(io.open(os.getenv("GX_PROBE_OUT") or "probe.txt", "w"))
local function p(...) out:write(table.concat({...}, " "), "\n") end

p("mame_version", emu.app_version and emu.app_version() or "?")
p("lua", _VERSION)

local m = manager.machine
p("machine", tostring(m ~= nil))
p("system", m.system and m.system.name or "?")

-- devices and spaces
local cpu = m.devices[":maincpu"]
p("maincpu", tostring(cpu ~= nil))
if cpu then
    local sp = cpu.spaces["program"]
    p("program_space", tostring(sp ~= nil))
    for _, fn in ipairs{"read_u8","read_u16","read_u32","read_i8"} do
        p("  space."..fn, tostring(sp[fn] ~= nil))
    end
    p("  space.install_write_tap", tostring(sp.install_write_tap ~= nil))
    p("  space.install_read_tap", tostring(sp.install_read_tap ~= nil))
end

-- notifiers
p("emu.add_machine_frame_notifier", tostring(emu.add_machine_frame_notifier ~= nil))
p("emu.register_frame_done", tostring(emu.register_frame_done ~= nil))

-- screens and snapshots
for tag, scr in pairs(m.screens) do
    p("screen", tag, scr.width.."x"..scr.height, "frame="..tostring(scr.frame_number))
    p("  snapshot", tostring(scr.snapshot ~= nil))
    p("  pixels",   tostring(scr.pixels ~= nil))
end
p("video.snapshot", tostring(m.video and m.video.snapshot ~= nil))

-- every device, so the GX customs can be addressed by tag
local n = 0
for tag, dev in pairs(m.devices) do n = n + 1 end
p("device_count", n)
for _, t in ipairs{":k056832",":k055673",":k055555",":k054338",":k053252",":k054539_1",":k054539_2",":soundcpu",":dasp",":palette",":screen"} do
    p("dev", t, tostring(m.devices[t] ~= nil))
end

-- memory regions (for ROM readback checks)
for tag, r in pairs(m.memory.regions) do p("region", tag, r.size) end

out:close()
print("PROBE DONE")
