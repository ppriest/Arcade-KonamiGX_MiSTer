# MAME kludges this core reproduces

Every GX set is `MACHINE_IMPERFECT_GRAPHICS`. This project follows MAME, including where MAME is
wrong (ROADMAP, "Follow MAME, including where MAME is wrong"), so the software model
(`scripts/render_model.py`) and later the RTL reproduce these on purpose. Each entry says where
the kludge is in MAME, what the model does, and what would settle the real behaviour.

Source references are to `src/mame/konami/konamigx_v.cpp` unless named.

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
| Sprite full-shadow darkening | `konamigx_mixer_init`: shadow table 3 is a fixed −80 on each channel. | Same. Not exercised by type-2 sprites (`K055555_FULLSHADOW` never set). | — |
