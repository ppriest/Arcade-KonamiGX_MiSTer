#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The core's audio against MAME's, from the main bench's +AUDIO log.

    python scripts/audio_compare.py debug/fj_audio/rtl_audio.txt debug/fj_audio/mame.wav

The log's S lines (sim/gx_main_tb, one a 48 kHz sample) become WAVs beside
it: <log>.wav (the board's mix) and <log>_k0.wav / <log>_k1.wav (each
K054539's own output). The two runs do not start at the same sample, so
the mix is aligned with MAME's by cross-correlating their loudness
envelopes; then each 100 ms window's level is printed, both runs, in dBFS,
and the difference. A steady difference is a gain; one that moves with the
music is a part mixed differently.
"""
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 48000
WIN = RATE // 10


def read_log(path):
    rows = []
    with open(path) as f:
        for line in f:
            if line.startswith("S "):
                rows.append([int(v) for v in line.split()[1:7]])
    a = np.array(rows, dtype=np.int64)
    return a[:, 0:4] / 256.0, a[:, 4:6].astype(np.float64)     # chips (8 fraction bits), mix


def write_wav(path, lr):
    pcm = np.clip(lr, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        n, ch, sw, rate = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(n)
    if sw != 2:
        raise SystemExit(f"{path}: {8 * sw}-bit, expected 16")
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64).reshape(-1, ch)
    if rate != RATE:
        raise SystemExit(f"{path}: {rate} Hz, expected {RATE}")
    return a


def envelope(lr):
    m = lr.mean(axis=1)
    n = len(m) // WIN
    return np.sqrt((m[: n * WIN].reshape(n, WIN) ** 2).mean(axis=1))


def db(x):
    return 20 * np.log10(np.maximum(x, 1e-3) / 32768.0)


def main():
    log, mame_wav = Path(sys.argv[1]), Path(sys.argv[2])
    chips, mix = read_log(log)
    write_wav(log.with_suffix(".wav"), mix)
    write_wav(log.with_name(log.stem + "_k0.wav"), chips[:, 0:2])
    write_wav(log.with_name(log.stem + "_k1.wav"), chips[:, 2:4])
    mame = read_wav(mame_wav)
    er, em = envelope(mix), envelope(mame)
    # the RTL's envelope slid along MAME's; the best offset in windows
    a, b = db(er) - db(er).mean(), db(em) - db(em).mean()
    best, lag = -1e18, 0
    for k in range(-len(a) + 20, len(b) - 20):
        lo, hi = max(0, -k), min(len(a), len(b) - k)
        if hi - lo < 20:
            continue
        c = float(np.dot(a[lo:hi], b[lo + k:hi + k])) / (hi - lo)
        if c > best:
            best, lag = c, k
    print(f"{len(mix)} RTL samples, {len(mame)} MAME; RTL window w is MAME's w{lag:+d} ({lag / 10:+.1f} s)")
    lo, hi = max(0, -lag), min(len(er), len(em) - lag)
    d = db(er[lo:hi]) - db(em[lo + lag:hi + lag])
    loud = db(em[lo + lag:hi + lag]) > -50
    print(f"over {int(loud.sum())} windows with sound: RTL - MAME median {np.median(d[loud]):+.1f} dB, "
          f"10th..90th percentile {np.percentile(d[loud], 10):+.1f}..{np.percentile(d[loud], 90):+.1f} dB")
    print("  t(s)   RTL dBFS  MAME dBFS   diff")
    for i in range(lo, hi, 10):
        print(f"{i / 10:6.1f}  {db(er[i]):8.1f}  {db(em[i + lag]):9.1f}  {db(er[i]) - db(em[i + lag]):+6.1f}")


if __name__ == "__main__":
    main()
