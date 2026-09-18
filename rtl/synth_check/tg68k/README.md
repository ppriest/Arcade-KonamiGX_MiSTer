# TG68K.C standalone Fmax — Phase 0 exit criterion 4

A Quartus project holding `TG68KdotC_Kernel` and nothing else, at the generics the core uses
(`sim/gx_boot_tb` and `Arcade-Psikyo_MiSTer` run the same ones). Every port is registered at the
boundary and the pins are virtual, so the report is the kernel's own register-to-register limit.

```
cd rtl/synth_check/tg68k
quartus_sh --flow compile tg68k_fmax -c tg68k_fmax      # after scripts/hwlock.py --require-no-jtag
```

## Result

5CSEBA6U23I7, speed grade 7, Quartus 17.0.2, `HIGH PERFORMANCE EFFORT`, seed 1, constrained at
100 MHz (`tg68k_fmax.sdc`) so the limit shows as negative slack:

| corner | Fmax |
|---|---|
| Slow 1100mV 100°C | **48.97 MHz** |
| Slow 1100mV −40°C | 49.58 MHz |

| resource | used |
|---|---|
| ALMs | 2,927 |
| registers | 1,514 |
| M10K | 2 |
| DSP | 6 |

The five worst paths all run from `exe_datatype[0]` to `regfile_rtl_1_bypass[*]`, about 20.4 ns —
the register-file bypass network, the same class of path `Arcade-Psikyo_MiSTer` found holding all
fifty of its worst paths at 48.74 MHz in its full design. Standalone and in-design agree to within
half a percent, so the limit is the kernel's own and not an artefact of its surroundings.

## What it decides

Under `clkena_in` the kernel is clocked at whatever clock drives it and merely *enabled* at the CPU
rate, so this number constrains the **clock**, not the 24 MHz the board runs its 68EC020 at.

- A shared 48 MHz `clk_sys` — the rate that divides exactly to every GX clock — would leave
  **2.0%** against a single placement's measurement. LESSONS_LEARNED's "*A clean STA summary is a
  property of one placement, not of the design*" is the reason that is not margin.
- A dedicated **`clk_cpu` at 24 MHz with `clkena_in` tied high** gives a 41.7 ns period against a
  20.4 ns path: roughly **2×** margin.

So the roadmap's plan — a separate CPU clock domain, with a real crossing to `clk_sys` — stands, now
on a measurement rather than on Psikyo's number.

## Carried with the measurement

`tg68k_fmax.sdc` is the constraint that produced these figures and is committed with them. A
constraint proved in a side project is not in the design (LESSONS_LEARNED, "[Seta] A constraint
proved in a side project is not in your design"): the core's own `.sdc` needs its own `clk_cpu`
entry and its own clock-crossing constraints when the CPU is wired in, and must be re-measured there.
