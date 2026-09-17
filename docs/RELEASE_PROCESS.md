# Release process

Two Quartus revisions, and they are held to different standards. This is the
procedure for turning a build into something other people run. Ported from
`Arcade-Psikyo_MiSTer`.

| | `KonamiGX_stp` (debug) | `KonamiGX` (release) |
| --- | --- | --- |
| Built by | `build_staged.py` (default) | `build_staged.py --rev KonamiGX` |
| Contains | ISSP probes, debug tracer, Debug OSD page | none of it -- compiled out |
| Timing | **may ship with negative slack** | **must close timing** |
| Goes to | our own DE10-nano | `releases/`, other people's hardware |

The asymmetry is the point. A debug build runs on hardware we control and in
front of someone who knows what a marginal path looks like, and the
instrumentation itself costs timing we have no intention of paying in a
release. A release build goes to hardware we cannot see, where a path that only
just fails becomes an intermittent glitch someone else has to chase and cannot
diagnose. So negative slack is qualified for the debug revision and
disqualifying for a release.

`build_staged.py` enforces this rather than leaving it to memory: it reads every
clock in the `.sta.summary` -- not just `clk_sys` -- and refuses to print the
deploy command if any of them fail, naming the offenders.
`--allow-negative-slack` overrides it, prints a warning instead, and obliges you
to state the shortfall in the release notes. Reach for it knowingly or not at
all.

It also gates on two things slack cannot see, both of which have shipped a
falsely-green build on a sibling core: that every block in `REQUIRED_INSTANCES`
survived to the fitted netlist, and that every macro in `REQUIRED_MACROS` is
defined in the revision's `.qsf`. Keep both lists current as modules land -- the
comments in the script say why.

Steps for a release:

1. `python scripts/build_staged.py --rev KonamiGX` -- must pass the timing gate,
   the presence gate and the macro gate.
2. Smoketest every parent set, which loads each and captures screenshots.
3. Deploy and play-test; the debug revision is the one to reach for if anything
   needs diagnosing.
4. Publish the `.rbf` and the `.mra` set together under `releases/`. They are
   coupled -- the SDRAM layout and the ROM-load path are both encoded in the
   MRAs, so a mismatched pair fails in ways that look like core bugs. Parents at
   the top level, clones in `releases/_alternatives/`.
5. Record the commit **and the fitter seed** from `build/BUILT_COMMIT` in the
   release notes. A commit alone does not identify a bitstream: on Seta, two
   builds of the same commit at seeds 2 and 7 differed in whether five games
   ran, and the one that ran them all had the worse worst slack.

**Current state: there is nothing to release.** Phase 0 has not started; see
[`ROADMAP.md`](ROADMAP.md).
