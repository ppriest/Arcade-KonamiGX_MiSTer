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
