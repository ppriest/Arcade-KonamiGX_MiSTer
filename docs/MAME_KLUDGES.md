# MAME kludges this core reproduces

Every GX set is `MACHINE_IMPERFECT_GRAPHICS`. This project follows MAME, including where MAME is
wrong (ROADMAP, "Follow MAME, including where MAME is wrong"), so the software model
(`scripts/render_model.py`) and later the RTL reproduce these on purpose. Each entry says where
the kludge is in MAME, what the model does, and what would settle the real behaviour.

Source references are to `src/mame/konami/konamigx_v.cpp` unless named.

## Where this core does NOT follow MAME

Each of these is a place MAME's own source calls its shortcut a hack, or where the chip
documentation says plainly what the hardware does. The core follows the chip; the difference from
MAME's picture is deliberate, and each needs a PCB capture to be called settled.

Per-tile mix codes and additive layers were rows here until mamedev `5c75784` (R. Belmont, Paul
Priest) took both into MAME, along with SHD PRI SEL conditions 1 and 2 (shadows drawn last, gated
by the topmost screen's priority) and SHD ON. The core follows that MAME; the reference captures
named `*-f<frame>g` are from it (built from the commit, single driver, `C:/mame-gx`). Condition 0
is still unimplemented in MAME, and there the core keeps the priority order as before.

| Behaviour | MAME | This core | Would settle it |
|---|---|---|---|
| Sprite DMA enable (K053246 OBJSET1 bit 4) | `dmastart_callback` copies the list only when DMAEN is set, but `konamigx_mixer_init(screen, 0)` leaves `m_gx_objdma` 0 and points the mixer at the K053247 RAM, so the copy never matters: the live list is drawn whatever DMAEN says. | The same, on purpose: jt053246's DMA runs whatever DMAEN says (`GX_DMA_ALWAYS`). `tokkae` keeps DMAEN clear (OBJSET1 0x20) with its sprites on screen. | A PCB with DMAEN cleared mid-game: do its sprites freeze? |
| Zoomed sprites | `k053247_sprites_draw_common` places each 16x16 tile of a sprite on its own -- start `o + ((zoom * t + 2048) >> 12)`, `zoom = (0x400000 + s/2) / s` -- and `zdrawgfxzoom32GP` samples it with stride `(16 << 19) / width`, so rounding restarts at every tile edge. | jt053246_scan and jtframe_draw step one accumulator across the whole sprite, which is closer to the chip. Zoomed sprites land a pixel or a row from MAME's (le2 attract, winspike f3000, salmndr2 f2400). | A PCB capture of a zoomed sprite. |
| Sprite mix codes (blending) | `konamigx_mixer` tags a sprite for blending if `color >> K055555_MIXSHIFT & 3`, but MIXSHIFT is 16 and the decoded colour is at most 14 bits, so no sprite is ever blended. | The sprite's attribute bits 9:8 (effect) are its mix code, through K054338 regs 13-14 like a tile's. Fantastic Journey's dancer stage covers its background gradient with a sprite of effect 1; the PCB shows the gradient, and so does Effect bits, with the spotlight beams translucent. (The top colour bits as the mix code hid the player's ship.) On; the benches' `+SPR_MIX=0` draws as MAME. | PCB footage of scenes with blended sprites. |
| Additive layer level | `k054338_device::set_alpha_level` inverts every level (`invert_alpha(1)`), and `gx_draw_tilemap_category` (5c75784) adds an additive layer at that inverted level. | The additive level is the register's own five bits, not inverted; plain blending is still inverted. Fantastic Journey steps its fire layer's level (K054338 reg 13, 0x28 to 0x20) to fade it out: inverted, the fire brightened and then vanished, which players reported against the PCB; as written it fades, and does on the board (`KonamiGX_30000047`). Sexy Parodius's ink (level 0-1 in the captures) adds little at those levels; it fades in and out, and looks right on the board with this rule (`KonamiGX_30000047`). | Settled for these two games by board play; Salamander 2 to check. |
| Interrupts armed by an enable write (`m_gx_syncen` bits 0-4) | Any write of `d56001` with bit 7 set arms one interrupt per enabled level, delivered at the next vblank (DMA end for level 3) even if the enable bit, or bit 7, has been cleared since. In the source since MAME 0.68, no rationale; no other Konami driver has it, and the K053252's INT1 is a level held until register 0x0e is written (furrtek's die trace). | Kept, because Twin Bee Yahhoo! waits for it, with two limits: an armed interrupt waits while bit 7 is clear, and a write from the level's own handler (the CPU's mask at that level) does not arm it. Without them Dragoon Might's and Gokujou Parodius's EEPROM saves are interrupted, and the handler's `d56000` write drops the 93C46's CS mid-command. | The GX board's interrupt logic (PALs or schematic). |
| The ESC's timing against the sprite DMA | The ESC protection runs in no time, so the K053246's copy never sees a half-written sprite list. | The ESC reads the list from SDRAM and takes real time; the copy is held off until it finishes (`jt053246_dma`'s `dma_hold`), so a frame gets a whole list a little late. | Whether the board's ESC can finish within a frame's vblank at all. |

| Kludge | MAME | Model | Would settle it |
|---|---|---|---|
| "Daisukiss bad shadow filter" | `konamigx_mixer`, `m_gx_primode` 4: a sprite whose attribute has bits 12-13 set, or equals `0x0800`, is dropped entirely. | Same, `sprite_objects`. | A PCB capture of a `daiskiss` scene with such a sprite. |
| "Tokkae shadow masking (INACCURATE)" | primodes 4 and 5: a shadow's priority is raised to `spri_min`, the highest priority of a layer that K055555 `SHD_ON` excludes. | Same, `mixer_shadow_setup`, `sprite_objects`. | The K055555 `SHD_ON` behaviour on hardware (MAME calls it a HACK). |
| `SHD_PRI_SEL` ignored | `shadowon[]` is set from it, then overwritten with zeros and re-derived from the K054338 shadow deltas (enabled if any channel is outside ±7). | Same. | K055555 datasheet p.66 behaviour on hardware. |
| Shadow enables lag one frame | The ±7 test reads `m_K054338_shdRGB`, which `update_all_shadows` refreshes only afterwards in the same call. | Uses the captured frame's registers: differs from MAME only on a frame where the deltas change. | Not a hardware question; a capture of such a frame would show whether it is visible. |
| Shadows are 15-bit | The sprite shadow path indexes the shadow table by `pix.as_rgb15()`: the destination is cut to 5 bits a channel, re-expanded with `pal5bit`, then offset. | Same, `shadow_table`. | Hardware shadow arithmetic (K054338). |
| Additive blend as inverted alpha | `gx_draw_basic_tilemaps`: an additive mix level `l` is drawn as alpha `~l & 0xff`; "FIXME: implement mixpri and additive". | Same, `stage_mix`. Not yet exercised by a capture. | A capture using additive mode, against the K054338 datasheet. |
| Alpha inverted | `konamigx_mixer_init`: `m_k054338->invert_alpha(1)`, so a level is `0x1f - mixset`. | Same, `k054338_alpha_level`. | K054338 datasheet. |
| Equal z-code tie-break | No silicon source found. `konamigx_mixer` draws the pool back to front in descending (priority, z-code, offset) and `zdrawgfxzoom32GP` skips only when the stored z is lower, so the lowest (z-code, priority, offset) is visible. | The sprite line buffer writes when (z-code, priority) is strictly lower, scanning in RAM order. First-wins over last-wins is shown by the captures (frames 3600, 6000); the priority term is not exercised yet. | A PCB capture of two overlapping equal-z sprites. |
| Which shadow a pixel keeps | `konamigx_mixer` draws the pool back to front; `zdrawgfxzoom32GP`'s shadow path skips a pixel whose shadow z-buffer holds a lower z-code or whose stored shadow priority is not higher, so of shadows at one priority the first drawn stands: the highest (shadow priority, z-code, offset). A lower-priority shadow can then stack on top of it. | `gx_obj_linebuf.v`'s shadow plane keeps the highest {shadow priority, z-code}, the later sprite winning a tie; one shadow per pixel. Frames 3600 and 6000 exercise the choice (12,872 shadow pixels). Twin Bee's `tbyahhoo-f3200` stacks two: a full-screen shadow (sprite 0) over the lower-left menu box's own shadows (sprites 28-32); MAME applies both and so dims the box's text, the RTL keeps the box's and leaves the text bright -- 4,371 pixels. The sprite chip's line buffer holds one shadow code a pixel, so the board may well show one; unverified. | A PCB capture of Twin Bee's attract (the "ためパンチ" demo screen) with the menu box on screen. |
| Per-tile alpha uses the LAST such tile's mix code | `gx_draw_basic_tilemaps` draws the tiles that carry a mix code (category 1) in one pass with `alpha_of(m_last_alpha_tile_mix_code & ~VMIXON)` — the code of whichever tile the callback saw last, not each tile's; the source calls the two bits it packs into `mixerflags` a "hack". | `gx_tilemap.sv` carries each tile's own 2-bit mix code to `gx_mixer.v`, which picks that pixel's alpha from it. Sexy Parodius's smoke is the case (its ink is drawn with a mix code; MAME leaves the black opaque). | A PCB capture of Sexy Parodius's ink stage. |
| Sprite full-shadow darkening | `konamigx_mixer_init`: shadow table 3 is a fixed −80 on each channel. | Same. Not exercised by type-2 sprites (`K055555_FULLSHADOW` never set). | — |

## The ESC (056734): MAME against its manual

`rtl/gx_esc.v` follows MAME's C (`konamigx.cpp`: `esc_w`, `konamigx_esc_alert`,
`generate_sprites`), and so do the differences below. They were found against a
description of the chip, [konami_056734_manual.md](https://github.com/rb6502/mame-ai-tips/blob/master/generated-gems/konami_056734_manual.md)
(rb6502/mame-ai-tips, "generated-gems": AI-generated, so a secondary source), and weighed
against the games' own code and captures. Nothing here has been changed in the core.

| Behaviour | MAME and this core | Manual | Evidence |
|---|---|---|---|
| Sort | none (MAME's `qsort` is commented out) | sorts by priority into lists | gokuparo's 68020 routine (0x2A2504, the one MAME's C translates) sorts into 256 lists |
| Word 0 of an output sprite | the priority | the output index | gokuparo writes a running counter (0xC0D732) |
| Output buffer | fixed 0xD20000 (`gx_esc.v` :98) | p2, alternating 0xD20000 / 0xD21000 | daiskiss's RUN parameters (0xC0B7D4) hold p2 = 0xD20000 in f2400/f4800, 0xD21000 in f3600/f6000/title |
| Entries scanned | 256 | 128 | daiskiss: entries 151-156 are the text-like sets behind the board runaway (ROADMAP); at 128 or above every entry yields nothing on all five captures |
| 0xFFFF piece | jumps, count unchanged | jumps, count reloaded at the target | per game: daiskiss's targets point at a count word (0x2119F8 -> 0x2119D6 = `0002`); tbyahhoo's and sexyparo's point at a piece. No daiskiss capture walks a jump |
| `color_set` of 0 | skipped | clears bits 4:0 | none |
| x | as MAME | +0x14 | absorbed by the per-set sprite offsets (`obj_hadj`) |
| Command packet | no state 1/3, no RESET reply, no RUN result at +0xC; an odd packet address is ignored (`gx_esc.v` :285) | states, replies, results; any address | nothing known depends on it |

IRQ 4 on completion (gated by 0xD56001 bit 4) matches all three.

**Patches.** The only program patches are tkmmpzdm's two (`scripts/build_mra.py` PATCHES,
MAME `init_konamigx`): 0x21CBA9 `11 -> 1F`, the K055555 input-enable byte in a fade-in, and
0x2043C7 `01 -> 00`, the checksum that rebalances it. They are not ESC workarounds and the
manual gives no reason to drop them. Remove both or neither; the test is tkmmpzdm's boot on the
core without them (do planes B-D return after the copyright screen?).

**Changes proposed, in order, none made:**
1. daiskiss `esc_count` 0x100 -> 0x80 (`gx_board_cfg.sv`): identical output on the captures,
   and the ESC stops reading the entries behind the runaway.
2. A per-set count reload on 0xFFFF, daiskiss only, once a capture walks a jump.
3. The output buffer from p2 per set, only together with however the K053246 is pointed at a
   buffer (unidentified).
4. Leave the sort, word 0, the zoom rounding, `color_set` 0 and x+0x14: each would move the core
   off MAME's pixels, and none has a PCB capture behind it.
