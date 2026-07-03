#!/usr/bin/env python3
"""Procedural gunshot synthesizer (audio.md §12.6 fallback pipeline).

Layered noise/sine synthesis of a 7.62x51 battle-rifle report (FAL-class), producing
distance-layer variants for the §12.1 catalog scheme. Deterministic (seeded) so variants
are reproducible. Requires numpy + scipy.

Usage:
    python3 tools/synth_gunshot.py [--out assets/audio/sfx] [--seed 42]

Outputs:
    fal_near.wav  — muzzle perspective (~0-60 m layer)
    fal_mid.wav   — mid distance (~60-180 m layer)
    fal_far.wav   — distant report (~180-500 m layer)
"""

import argparse
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 48000


def _t(dur: float) -> np.ndarray:
    return np.arange(int(SR * dur)) / SR


def _env(t: np.ndarray, tau: float, attack: float = 0.0) -> np.ndarray:
    """Exponential decay with optional linear attack ramp."""
    e = np.exp(-t / tau)
    if attack > 0.0:
        e *= np.clip(t / attack, 0.0, 1.0)
    return e


def _noise(rng: np.random.Generator, n: int) -> np.ndarray:
    return rng.standard_normal(n)


def _bandpass(x: np.ndarray, lo: float, hi: float, order: int = 4) -> np.ndarray:
    sos = signal.butter(order, [lo, hi], btype="band", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def _lowpass(x: np.ndarray, cutoff: float, order: int = 4) -> np.ndarray:
    sos = signal.butter(order, cutoff, btype="low", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def _highpass(x: np.ndarray, cutoff: float, order: int = 2) -> np.ndarray:
    sos = signal.butter(order, cutoff, btype="high", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def _pitch_drop(t: np.ndarray, f_start: float, f_end: float, tau: float) -> np.ndarray:
    """Sine whose frequency decays exponentially f_start -> f_end (the 'thump')."""
    f = f_end + (f_start - f_end) * np.exp(-t / tau)
    phase = 2.0 * np.pi * np.cumsum(f) / SR
    return np.sin(phase)


def _delay_taps(x: np.ndarray, taps: list[tuple[float, float, float]]) -> np.ndarray:
    """Add discrete early reflections: (delay_s, gain, lowpass_hz) per tap."""
    out = x.copy()
    for delay_s, gain, lp in taps:
        d = int(delay_s * SR)
        if d >= len(x):
            continue
        tap = _lowpass(x, lp) * gain
        out[d:] += tap[: len(x) - d]
    return out


def _finish(x: np.ndarray, drive: float, peak_db: float = -1.0) -> np.ndarray:
    """Soft-clip saturation for punch, then peak-normalize."""
    x = np.tanh(x * drive) / np.tanh(drive)
    x *= (10.0 ** (peak_db / 20.0)) / max(1e-9, np.max(np.abs(x)))
    return x


def synth_near(rng: np.random.Generator) -> np.ndarray:
    """Muzzle perspective: hard transient, mid crack, deep thump, action click, short tail."""
    dur = 1.2
    t = _t(dur)
    n = len(t)

    transient = _highpass(_noise(rng, n), 1500) * _env(t, 0.003) * 1.0
    crack = _bandpass(_noise(rng, n), 700, 4500) * _env(t, 0.045) * 0.9
    thump = _pitch_drop(t, 160.0, 52.0, 0.05) * _env(t, 0.11) * 1.1
    body = _lowpass(_noise(rng, n), 900) * _env(t, 0.08) * 0.5

    # Action cycling click ~55 ms after the shot.
    click = np.zeros(n)
    ci = int(0.055 * SR)
    cn = int(0.008 * SR)
    click[ci : ci + cn] = _highpass(_noise(rng, cn), 3000) * _env(_t(0.008), 0.002) * 0.25

    tail = _lowpass(_noise(rng, n), 1400) * _env(t, 0.30, attack=0.01) * 0.16
    tail = _delay_taps(tail, [(0.09, 0.5, 1000.0), (0.17, 0.35, 700.0), (0.27, 0.22, 500.0)])

    return _finish(transient + crack + thump + body + click + tail, drive=2.6)


def synth_mid(rng: np.random.Generator) -> np.ndarray:
    """~100 m: transient softened, crack thinned, thump still present, longer tail."""
    dur = 1.6
    t = _t(dur)
    n = len(t)

    crack = _bandpass(_noise(rng, n), 400, 2200) * _env(t, 0.05, attack=0.002) * 0.7
    thump = _pitch_drop(t, 110.0, 48.0, 0.07) * _env(t, 0.16, attack=0.003) * 1.0
    body = _lowpass(_noise(rng, n), 600) * _env(t, 0.14, attack=0.004) * 0.6
    tail = _lowpass(_noise(rng, n), 800) * _env(t, 0.45, attack=0.02) * 0.3
    tail = _delay_taps(tail, [(0.14, 0.5, 600.0), (0.30, 0.32, 450.0), (0.50, 0.2, 350.0)])

    return _finish(crack + thump + body + tail, drive=2.0)


def synth_far(rng: np.random.Generator) -> np.ndarray:
    """~300 m: no transient — a dark rolling boom with long tail and slap echoes."""
    dur = 2.2
    t = _t(dur)
    n = len(t)

    boom = _lowpass(_noise(rng, n), 420) * _env(t, 0.22, attack=0.012) * 1.0
    thump = _pitch_drop(t, 80.0, 42.0, 0.10) * _env(t, 0.25, attack=0.012) * 0.8
    rumble = _lowpass(_noise(rng, n), 180) * _env(t, 0.55, attack=0.03) * 0.5
    tail = _lowpass(_noise(rng, n), 350) * _env(t, 0.7, attack=0.05) * 0.35
    tail = _delay_taps(tail, [(0.25, 0.5, 300.0), (0.52, 0.34, 250.0), (0.85, 0.2, 200.0)])

    return _finish(boom + thump + rumble + tail, drive=1.6)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="assets/audio/sfx", help="output directory")
    ap.add_argument("--seed", type=int, default=42, help="RNG seed (reproducible variants)")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in (("fal_near", synth_near), ("fal_mid", synth_mid), ("fal_far", synth_far)):
        rng = np.random.default_rng(args.seed)
        data = (fn(rng) * 32767.0).astype(np.int16)
        path = out / f"{name}.wav"
        wavfile.write(path, SR, data)
        print(f"wrote {path} ({len(data) / SR:.2f}s, {SR} Hz mono 16-bit)")


if __name__ == "__main__":
    main()
