#!/usr/bin/env python3
"""Synthesise the game's sounds: snow footsteps and soft wind. No samples are used.

Every sound is generated from random numbers by this script, so the outputs are
original works dedicated to the public domain (CC0 1.0); see CREDITS.md.

    python3 tools/make_sounds.py game/audio

Footstep model (cold, dry snow): a footfall is a heel strike followed by a roll onto
the toes. Both phases crush ice grains: hundreds of tiny clicks whose rate follows the
pressure envelope. Each click is a very short burst of band-passed noise; the
amplitude distribution is heavy-tailed so a few grains snap loudly ("crunch"). A
faint narrow-band squeak (cold snow below about -10 C) and a soft low thump of
compacting snow complete it.
"""
import sys
import wave
from pathlib import Path

import numpy as np
from scipy import signal

SR = 44100


def bandpass(x, lo, hi, order=2):
    sos = signal.butter(order, [lo, hi], btype="band", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def highpass(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, btype="high", fs=SR, output="sos"), x)


def lowpass(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, btype="low", fs=SR, output="sos"), x)


def envelope(t, t0, attack, decay):
    e = np.zeros_like(t)
    a = (t >= t0) & (t < t0 + attack)
    e[a] = (t[a] - t0) / attack
    d = t >= t0 + attack
    e[d] = np.exp(-(t[d] - t0 - attack) / decay)
    return e


def footstep(rng: np.random.Generator, heavy: bool = False) -> np.ndarray:
    dur = 0.42 if heavy else 0.36
    n = int(SR * dur)
    t = np.arange(n) / SR
    heel_t = 0.008
    toe_t = rng.uniform(0.09, 0.13) * (0.85 if heavy else 1.0)
    pressure = 1.0 * envelope(t, heel_t, 0.012, 0.05) + 0.75 * envelope(t, toe_t, 0.03, 0.07)
    pressure *= rng.uniform(0.85, 1.15)

    # Grain events: Poisson with a rate that follows the pressure.
    rate = 9000.0 * pressure * (1.25 if heavy else 1.0)  # clicks per second at peak
    events = rng.random(n) < rate / SR
    amps = np.minimum(rng.pareto(2.2, n), 4.0) * events * (0.4 + pressure)  # capped heavy tail
    out = np.zeros(n)
    # Three grain families with different sizes (pitch) and lengths.
    for lo, hi, length_ms, share in ((900, 2600, 2.5, 0.35), (2200, 5500, 1.4, 0.4), (4000, 9000, 0.7, 0.25)):
        k = int(SR * length_ms / 1000)
        kernel = bandpass(rng.standard_normal(k * 3), lo, hi)[k:2 * k] * np.exp(-np.linspace(0, 5, k))
        pick = rng.random(n) < share
        out += signal.fftconvolve(amps * pick, kernel)[:n]
    # Compacting snow: soft low thump at the heel.
    thump_f = rng.uniform(70, 110)
    out += 0.9 * np.sin(2 * np.pi * thump_f * t) * envelope(t, heel_t, 0.004, 0.035) * (1.3 if heavy else 1.0)
    # Broadband crush under the grains.
    out += 0.12 * bandpass(rng.standard_normal(n), 300, 3000) * pressure
    # Faint squeak of very cold snow.
    sq_f = rng.uniform(900, 1400)
    squeak = bandpass(rng.standard_normal(n), sq_f * 0.97, sq_f * 1.03, order=3) * envelope(t, toe_t, 0.04, 0.06)
    out += 0.6 * squeak * rng.uniform(0.3, 1.0)
    out = highpass(lowpass(out, 9000), 60)
    out *= np.clip(1.0 - (t - (dur - 0.05)) / 0.05, 0.0, 1.0)  # no click at the end
    # Normalise on a high percentile, then soft-limit, so a single loud grain cannot
    # squash the rest of the step.
    out /= np.percentile(np.abs(out), 99.5) + 1e-9
    return np.tanh(out * 0.7) * (0.75 if heavy else 0.65)


def wind_loop(rng: np.random.Generator, seconds: float = 60.0, fade: float = 4.0) -> np.ndarray:
    n = int(SR * (seconds + fade))
    t = np.arange(n) / SR

    def smooth_random(rate_hz, length):
        pts = int(length / SR * rate_hz) + 4
        ctrl = rng.standard_normal(pts)
        x = np.linspace(0, pts - 3, length)
        return np.interp(x, np.arange(pts), ctrl)

    gust = 0.55 + 0.3 * smooth_random(0.08, n) + 0.15 * smooth_random(0.4, n)
    gust = np.clip(gust, 0.15, 1.2)
    chans = []
    for ch in range(2):
        white = rng.standard_normal(n)
        brown = np.cumsum(white)
        brown = highpass(brown, 25, order=2)
        brown /= np.max(np.abs(brown)) + 1e-9
        pink = signal.lfilter([0.049922, -0.095993, 0.050612, -0.004408], [1, -2.494956, 2.017265, -0.522189], white)
        pink /= np.max(np.abs(pink)) + 1e-9
        # Time-varying resonance: a soft whistle that rises with the gusts.
        centre = 380 + 420 * gust + 60 * smooth_random(0.3, n)
        whistle = np.zeros(n)
        block = 2048
        zi = None
        for s in range(0, n, block):
            f = float(np.mean(centre[s:s + block]))
            b, a = signal.iirpeak(f, 6.0, fs=SR)
            if zi is None:
                zi = signal.lfilter_zi(b, a) * 0
            whistle[s:s + block], zi = signal.lfilter(b, a, pink[s:s + block], zi=zi)
        mix = 0.75 * lowpass(brown, 500) + 0.25 * lowpass(pink, 2500) + 0.35 * whistle
        chans.append(mix * gust)
    stereo = np.stack(chans, axis=1)
    # Seamless loop: crossfade the tail into the head.
    k = int(SR * fade)
    head, tail = stereo[:k], stereo[-k:]
    w = np.linspace(0, 1, k)[:, None]
    stereo = stereo[:-k].copy()
    stereo[:k] = head * w + tail * (1 - w)
    return stereo / (np.max(np.abs(stereo)) + 1e-9) * 0.5


def write_wav(path: Path, data: np.ndarray) -> None:
    pcm = np.clip(data * 32767, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1 if pcm.ndim == 1 else pcm.shape[1])
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "game/audio")
    (out / "footsteps").mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(2026)
    for i in range(8):
        write_wav(out / "footsteps" / f"snow_step_{i:02d}.wav", footstep(rng))
    for i in range(4):
        write_wav(out / "footsteps" / f"snow_run_{i:02d}.wav", footstep(rng, heavy=True))
    wav = out / "wind_loop.wav"
    write_wav(wav, wind_loop(rng))
    # Ogg Vorbis keeps the 60 s loop small; fall back to WAV if ffmpeg is missing.
    import shutil
    import subprocess
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(wav), "-c:a", "libvorbis", "-q:a", "3",
                        str(out / "wind_loop.ogg")], check=True)
        wav.unlink()
    print("sounds written to", out)


if __name__ == "__main__":
    main()
