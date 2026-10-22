#!/usr/bin/env python3
"""RF validation of the gNB (USRP) with a HackRF One as an independent receiver.

The gNB transmits; the HackRF only listens (cabled through attenuators or inside a shielded box).
This script turns what the HackRF recorded into checks against the gNB configuration:

  params   frequencies and sample rate derived from the gNB config (used by scripts/rf/rf.sh)
  sweep    hackrf_sweep CSV -> spectrum plot + occupied band around the carrier
  analyze  hackrf_transfer IQ capture -> spectrum, spectrogram, SSB search (PSS), PCI (PSS+SSS),
           SSB burst period, frequency offset, level/saturation checks; writes report.md/json
  selftest synthetic NR downlink (PCI 1, SSB every 20 ms, frequency offset) -> analyze must find it

Radio parameters come from the gNB YAML (cell_cfg: dl_arfcn, channel_bandwidth_MHz, common_scs,
pci) given with --gnb-config or the GNB_CFG env var; default is this repo's ZMQ profile
configs/gnb/gnb_zmq_<BW>mhz.yml. Formulas: NR-ARFCN TS 38.104 5.4.2.1, sync raster (GSCN)
TS 38.104 5.4.3.1, PSS/SSS TS 38.211 7.4.2.2-7.4.2.3, SS/PBCH block grid TS 38.211 7.4.3.1.
"""
import argparse
import json
import math
import os
import re
import sys
import time

import numpy as np
from scipy import signal

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HACKRF_MAX_FS = 20e6
CORR_THRESHOLD = 0.2       # normalized PSS correlation needed to call it a detection (noise ~0.01)
PPM_SEARCH = 25            # frequency search range: HackRF crystal (+-20 ppm) + gNB SDR (+-2..5 ppm)


# --------------------------------------------------------------------------------------------
# Configuration and frequencies
# --------------------------------------------------------------------------------------------
def arfcn_to_hz(n):
    """NR-ARFCN -> RF reference frequency (TS 38.104 table 5.4.2.1-1)."""
    if n < 600000:
        return 5e3 * n
    if n < 2016667:
        return 3000e6 + 15e3 * (n - 600000)
    return 24250.08e6 + 60e3 * (n - 2016667)


def gscn_candidates(f_lo, f_hi):
    """SS block center frequencies allowed by the synchronization raster inside [f_lo, f_hi]."""
    out = []
    if f_lo < 3000e6:   # SS_REF = N*1200 kHz + M*50 kHz, M in {1,3,5}
        for n in range(max(1, int(f_lo // 1.2e6) - 1), int(min(f_hi, 3000e6) // 1.2e6) + 2):
            out += [n * 1.2e6 + m * 50e3 for m in (1, 3, 5)]
    if f_hi >= 3000e6:  # SS_REF = 3000 MHz + N*1.44 MHz
        for n in range(max(0, int((f_lo - 3000e6) // 1.44e6) - 1), int((f_hi - 3000e6) // 1.44e6) + 2):
            out.append(3000e6 + n * 1.44e6)
    return sorted(f for f in out if f_lo <= f <= f_hi)


def load_gnb_config(path):
    text = open(path).read()
    try:
        import yaml
        cell = (yaml.safe_load(text) or {}).get("cell_cfg", {}) or {}
        get = cell.get
        ssb = cell.get("ssb", {}) or {}
        ssb_period = ssb.get("ssb_period")
    except ImportError:   # fall back to "key: value" lines
        vals = dict(re.findall(r"^\s*(\w+):\s*([\w.]+)", text, re.M))
        get = lambda k, d=None: vals.get(k, d)  # noqa: E731
        ssb_period = vals.get("ssb_period")
    return {
        "dl_arfcn": int(get("dl_arfcn")),
        "band": get("band"),
        "bw_mhz": float(get("channel_bandwidth_MHz")),
        "scs_khz": int(get("common_scs", 15)),
        "pci": int(get("pci", 1)),
        "ssb_period_ms": int(ssb_period) if ssb_period else None,
        "source": os.path.relpath(path, ROOT) if path.startswith(ROOT) else path,
    }


def repo_ssb_arfcn(bw):
    """SSB ARFCN of this repo's profile (the UE config stores it; it must equal the gNB's)."""
    ue = os.path.join(ROOT, "configs", "ue", f"ue_zmq_{bw}mhz.conf")
    if os.path.exists(ue):
        m = re.search(r"^ssb_nr_arfcn\s*=\s*(\d+)", open(ue).read(), re.M)
        if m:
            return int(m.group(1))
    return None


def resolve_config(args):
    path = getattr(args, "gnb_config", None) or os.environ.get("GNB_CFG")
    bw_env = os.environ.get("BW") or os.environ.get("BW_MHZ") or "10"
    repo_profile = not path
    if repo_profile:
        path = os.path.join(ROOT, "configs", "gnb", f"gnb_zmq_{bw_env}mhz.yml")
    if not os.path.exists(path):
        sys.exit(f"gNB config not found: {path} (set GNB_CFG=/path/to/gnb.yml)")
    cfg = load_gnb_config(path)
    for key in ("dl_arfcn", "pci", "scs_khz"):
        v = getattr(args, key, None)
        if v is not None:
            cfg[key] = v
    if getattr(args, "bw", None):
        cfg["bw_mhz"] = args.bw
    ssb = getattr(args, "ssb_arfcn", None) or os.environ.get("SSB_ARFCN")
    if not ssb and repo_profile:
        ssb = repo_ssb_arfcn(int(cfg["bw_mhz"]))
    cfg["ssb_arfcn"] = int(ssb) if ssb else None
    cfg["ssb_scs_khz"] = getattr(args, "ssb_scs", None) or cfg["scs_khz"]
    cfg["fc_hz"] = arfcn_to_hz(cfg["dl_arfcn"])
    cfg["ssb_hz"] = arfcn_to_hz(cfg["ssb_arfcn"]) if cfg["ssb_arfcn"] else None
    # sample rate: smallest standard rate that covers the channel, capped by the HackRF (20 Msps)
    cfg["fs_hz"] = next((r for r in (7.68e6, 15.36e6, 23.04e6) if r >= 1.2 * cfg["bw_mhz"] * 1e6), 23.04e6)
    cfg["fs_hz"] = min(cfg["fs_hz"], HACKRF_MAX_FS)
    return cfg


# --------------------------------------------------------------------------------------------
# PSS / SSS sequences (TS 38.211 7.4.2.2 and 7.4.2.3)
# --------------------------------------------------------------------------------------------
def _m_sequence(init, taps, length=127):
    x = list(init) + [0] * (length - 7)
    for i in range(length - 7):
        x[i + 7] = sum(x[i + t] for t in taps) % 2
    return np.array(x)


_X_PSS = _m_sequence([0, 1, 1, 0, 1, 1, 1], (4, 0))
_X0_SSS = _m_sequence([1, 0, 0, 0, 0, 0, 0], (4, 0))
_X1_SSS = _m_sequence([1, 0, 0, 0, 0, 0, 0], (1, 0))


def pss(nid2):
    n = np.arange(127)
    return 1 - 2 * _X_PSS[(n + 43 * nid2) % 127]


def sss(nid1, nid2):
    n = np.arange(127)
    m0 = 15 * (nid1 // 112) + 5 * nid2
    m1 = nid1 % 112
    return (1 - 2 * _X0_SSS[(n + m0) % 127]) * (1 - 2 * _X1_SSS[(n + m1) % 127])


# PSS/SSS sit on subcarriers k = 56..182 of the 240-subcarrier SS block, whose center is k = 120.
SSB_K = np.arange(56, 183) - 120


def symbol_waveform(values, scs, fs):
    """Useful part (no CP) of one OFDM symbol carrying `values` on SSB_K, sampled at fs."""
    n = int(round(fs / scs))
    t = np.arange(n) / fs
    return (values[None, :] * np.exp(2j * np.pi * np.outer(t, SSB_K * scs))).sum(axis=1)


# --------------------------------------------------------------------------------------------
# IQ helpers
# --------------------------------------------------------------------------------------------
def load_iq(path, max_s=None, fs=None):
    raw = np.fromfile(path, dtype=np.int8, count=-1 if not (max_s and fs) else int(2 * max_s * fs))
    clip = float(np.mean((raw == 127) | (raw == -128)))
    x = raw.astype(np.float32).view(np.complex64) / 128.0 if raw.size % 2 == 0 else None
    if x is None:
        sys.exit(f"{path}: odd number of bytes, not an int8 IQ file")
    return x - x.mean(), clip   # HackRF DC offset at the tuned frequency


def baseband(x, fs, f_shift, fs_out):
    """Moves f_shift (Hz, relative to the tuning) to 0 and resamples to fs_out."""
    n = np.arange(x.size)
    y = x * np.exp(-2j * np.pi * f_shift / fs * n).astype(np.complex64)
    g = math.gcd(int(round(fs_out)), int(round(fs)))
    return signal.resample_poly(y, int(round(fs_out)) // g, int(round(fs)) // g).astype(np.complex64)


def norm_corr(x, tmpl):
    """|<x, tmpl>|^2 / (|x|^2 |tmpl|^2) over every window position (0..1)."""
    c = signal.fftconvolve(x, np.conj(tmpl[::-1]), mode="valid")
    e = signal.fftconvolve(np.abs(x) ** 2, np.ones(tmpl.size), mode="valid")
    return np.abs(c) ** 2 / (np.sum(np.abs(tmpl) ** 2) * np.maximum(e, 1e-12))


def db(x):
    return 10 * np.log10(np.maximum(x, 1e-20))


# --------------------------------------------------------------------------------------------
# SSB search
# --------------------------------------------------------------------------------------------
def find_ssb(x, fs, fc, cfg, log=print):
    """Searches GSCN candidates x frequency offsets x N_ID2. Returns the best detection or None."""
    scs = cfg["ssb_scs_khz"] * 1e3
    fr = 256 * scs                                   # 3.84 Msps @15 kHz: SSB (3.6 MHz) fits
    half_ssb = 120 * scs
    ppm_hz = PPM_SEARCH * 1e-6 * fc
    usable = 0.45 * fs - half_ssb - ppm_hz
    if cfg["ssb_hz"]:
        cands = [cfg["ssb_hz"]]
    else:
        cands = [f for f in gscn_candidates(fc - usable, fc + usable)]
    if not cands:
        return None
    seg = x[: int(min(x.size, 0.045 * fs))]           # 45 ms: at least two 20 ms bursts
    tmpl = {nid2: symbol_waveform(pss(nid2), scs, fr) for nid2 in range(3)}
    step = scs / 3
    offsets = np.arange(-ppm_hz, ppm_hz + step, step)
    best = None
    log(f"  searching {len(cands)} SSB raster position(s) x {offsets.size} offsets x 3 PSS ...")
    for f_ss in cands:
        y = baseband(seg, fs, f_ss - fc, fr)
        n = np.arange(y.size)
        for off in offsets:
            z = y * np.exp(-2j * np.pi * off / fr * n).astype(np.complex64)
            for nid2, t in tmpl.items():
                m = norm_corr(z, t)
                i = int(np.argmax(m))
                if best is None or m[i] > best["metric"]:
                    best = {"f_ss": f_ss, "offset_hz": float(off), "nid2": nid2, "metric": float(m[i])}
    if best["metric"] < CORR_THRESHOLD:
        return dict(best, found=False)
    # fine frequency search around the winner
    y = baseband(seg, fs, best["f_ss"] - fc, fr)
    n = np.arange(y.size)
    for off in np.arange(best["offset_hz"] - step, best["offset_hz"] + step, scs / 60):
        m = norm_corr(y * np.exp(-2j * np.pi * off / fr * n).astype(np.complex64), tmpl[best["nid2"]])
        if m.max() > best["metric"]:
            best.update(offset_hz=float(off), metric=float(m.max()))
    return dict(best, found=True)


def characterize_ssb(x, fs, fc, cfg, det):
    """With the winning (frequency, N_ID2): every SSB in the capture, burst period, N_ID1/PCI."""
    scs = cfg["ssb_scs_khz"] * 1e3
    fr = 256 * scs
    y = baseband(x, fs, det["f_ss"] - fc + det["offset_hz"], fr)
    tmpl = symbol_waveform(pss(det["nid2"]), scs, fr)
    m = norm_corr(y, tmpl)
    peaks, _ = signal.find_peaks(m, height=max(CORR_THRESHOLD, 0.5 * m.max()), distance=256)
    t_ms = peaks / fr * 1e3
    bursts = []                                       # SSBs of one burst lie within a 5 ms half frame
    for p, t in zip(peaks, t_ms):
        if not bursts or t - bursts[-1][0] > 5:
            bursts.append([t, []])
        bursts[-1][1].append(p)
    starts = [b[0] for b in bursts]
    period = float(np.median(np.diff(starts))) if len(starts) > 1 else None
    # SSS: 2 symbols after the PSS (normal CP = 18 samples at 256 samples/symbol)
    dist = 2 * (256 + 18)
    k_bins = SSB_K % 256
    d_pss = pss(det["nid2"])
    cands = np.array([sss(n1, det["nid2"]) for n1 in range(336)])
    score = np.zeros(336)
    for p in peaks:
        if p + dist + 256 > y.size:
            continue
        yp = np.fft.fft(y[p:p + 256])[k_bins] / 256
        ys = np.fft.fft(y[p + dist:p + dist + 256])[k_bins] / 256
        h = yp / d_pss                                # channel estimate from the PSS
        eq = ys * np.conj(h) / np.maximum(np.abs(h) ** 2, 1e-12)
        score += np.abs(cands @ eq)
    nid1 = int(np.argmax(score))
    srt = np.sort(score)
    snr = det["metric"] / max(1 - det["metric"], 1e-6)
    return {
        "metric_curve": (np.arange(m.size) / fr * 1e3, m),
        "n_ssb": int(len(peaks)),
        "n_bursts": len(bursts),
        "ssb_per_burst": int(round(np.median([len(b[1]) for b in bursts]))) if bursts else 0,
        "period_ms": period,
        "nid1": nid1,
        "pci": 3 * nid1 + det["nid2"],
        "sss_margin": float(srt[-1] / srt[-2]) if srt[-2] > 0 else float("inf"),
        "pss_snr_db": float(db(snr)),
        "ssb_level_dbfs": float(db(np.mean(np.abs(y[peaks[0]:peaks[0] + 256]) ** 2))) if len(peaks) else None,
    }


# --------------------------------------------------------------------------------------------
# Spectrum
# --------------------------------------------------------------------------------------------
def occupied_band(freqs, psd_db, floor_db, above=10.0):
    """Lowest/highest frequency more than `above` dB over the noise floor (None if nothing)."""
    idx = np.where(psd_db > floor_db + above)[0]
    if idx.size == 0:
        return None
    return float(freqs[idx[0]]), float(freqs[idx[-1]])


def spectrum(x, fs, fc):
    nfft = 4096
    f, p = signal.welch(x, fs, nperseg=nfft, return_onesided=False, scaling="density")
    f, p = np.fft.fftshift(f), np.fft.fftshift(p)
    frames = x[: (x.size // nfft) * nfft].reshape(-1, nfft)
    hold = np.fft.fftshift((np.abs(np.fft.fft(frames * np.hanning(nfft), axis=1)) ** 2).max(axis=0))
    return f + fc, db(p), db(hold / (fs * nfft))


# --------------------------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------------------------
def cmd_params(args):
    cfg = resolve_config(args)
    print(f"RF_FC_HZ={int(cfg['fc_hz'])}")
    print(f"RF_FS_HZ={int(cfg['fs_hz'])}")
    print(f"RF_BW_MHZ={cfg['bw_mhz']:g}")
    print(f"RF_SSB_HZ={int(cfg['ssb_hz']) if cfg['ssb_hz'] else ''}")
    print(f"RF_SWEEP_LO_MHZ={int(cfg['fc_hz'] / 1e6 - cfg['bw_mhz'] / 2 - 10)}")
    print(f"RF_SWEEP_HI_MHZ={int(math.ceil(cfg['fc_hz'] / 1e6 + cfg['bw_mhz'] / 2 + 10))}")
    print(f"RF_SOURCE={cfg['source']}")


def plt_mod():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def cmd_sweep(args):
    cfg = resolve_config(args)
    rows = {}
    for line in open(args.csv):
        p = [s.strip() for s in line.split(",")]
        if len(p) < 7:
            continue
        lo, step = float(p[2]), float(p[4])
        for i, v in enumerate(p[6:]):
            f = lo + (i + 0.5) * step
            rows[f] = max(rows.get(f, -200.0), float(v))   # max-hold over all sweeps
    if not rows:
        sys.exit(f"{args.csv}: no sweep data")
    f = np.array(sorted(rows))
    p = np.array([rows[k] for k in f])
    floor = float(np.percentile(p, 20))
    band = occupied_band(f, p, floor)
    out = os.path.dirname(os.path.abspath(args.csv))
    plt = plt_mod()
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.plot(f / 1e6, p, lw=0.8)
    lo, hi = cfg["fc_hz"] - cfg["bw_mhz"] * 5e5, cfg["fc_hz"] + cfg["bw_mhz"] * 5e5
    ax.axvspan(lo / 1e6, hi / 1e6, color="tab:green", alpha=0.12, label="canal configurado")
    ax.axhline(floor, color="gray", ls=":", label="piso de ruido")
    ax.set(xlabel="Frecuencia (MHz)", ylabel="Potencia (dB, max-hold)",
           title=f"hackrf_sweep alrededor de {cfg['fc_hz'] / 1e6:.3f} MHz")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(out, "sweep.png"), dpi=120)
    print(f"  floor {floor:.1f} dB, peak {p.max():.1f} dB at {f[np.argmax(p)] / 1e6:.3f} MHz")
    if band:
        print(f"  occupied (>10 dB over floor): {band[0] / 1e6:.3f} - {band[1] / 1e6:.3f} MHz "
              f"({(band[1] - band[0]) / 1e6:.2f} MHz); configured {lo / 1e6:.3f} - {hi / 1e6:.3f} MHz")
    else:
        print("  nothing more than 10 dB above the floor: no carrier visible")
    print(f"  plot: {os.path.relpath(os.path.join(out, 'sweep.png'), ROOT)}")
    return 0 if band else 1


def analyze(path, cfg, fc, fs, out_dir, log=print):
    """Full analysis of one capture. Returns (checks, report dict)."""
    x, clip = load_iq(path, max_s=2.0, fs=fs)
    rms_dbfs = float(db(np.mean(np.abs(x) ** 2)))
    log(f"  {x.size / fs:.2f} s at {fs / 1e6:.2f} Msps, tuned {fc / 1e6:.4f} MHz, level {rms_dbfs:.1f} dBFS, "
        f"clipped samples {100 * clip:.3f} %")
    f, psd_db, hold_db = spectrum(x, fs, fc)
    floor = float(np.percentile(psd_db, 10))
    band_avg = occupied_band(f, psd_db, floor)
    band_hold = occupied_band(f, hold_db, float(np.percentile(hold_db, 10)))

    det = find_ssb(x, fs, fc, cfg, log)
    ssb = characterize_ssb(x, fs, fc, cfg, det) if det and det["found"] else None

    checks = []   # (status, text): status in PASS/FAIL/WARN/INFO

    def chk(status, text):
        checks.append((status, text))

    chk("WARN" if clip > 1e-3 else "PASS",
        f"saturación: {100 * clip:.3f} % de muestras recortadas" + (" -> más atenuación o menos ganancia (-l/-g)"
                                                                    if clip > 1e-3 else ""))
    if not ssb:
        chk("FAIL", f"no se encontró ningún SSB (mejor correlación PSS {det['metric'] if det else 0:.3f}, "
                    f"umbral {CORR_THRESHOLD}). ¿El gNB transmite? ¿Frecuencia o ganancia correctas?")
    else:
        f_meas = det["f_ss"] + det["offset_hz"]
        chk("PASS", f"SSB detectado: {ssb['n_ssb']} SSB en {ssb['n_bursts']} ráfagas, SNR en la banda del SSB ~{ssb['pss_snr_db']:.1f} dB")
        exp_pci = cfg["pci"]
        chk("PASS" if ssb["pci"] == exp_pci else "FAIL",
            f"PCI medido {ssb['pci']} (N_ID1 {ssb['nid1']}, N_ID2 {det['nid2']}), configurado {exp_pci}"
            + (f"; margen SSS {ssb['sss_margin']:.1f}x" if ssb["sss_margin"] != float("inf") else ""))
        ppm = det["offset_hz"] / fc * 1e6
        if cfg["ssb_hz"]:
            chk("PASS" if abs(ppm) <= PPM_SEARCH else "FAIL",
                f"frecuencia del SSB {f_meas / 1e6:.4f} MHz, esperada {cfg['ssb_hz'] / 1e6:.4f} MHz "
                f"(ARFCN {cfg['ssb_arfcn']}); diferencia {det['offset_hz'] / 1e3:+.1f} kHz = {ppm:+.1f} ppm "
                "(error de reloj HackRF+USRP)")
        else:
            chk("INFO", f"SSB en el raster {det['f_ss'] / 1e6:.4f} MHz (+{det['offset_hz'] / 1e3:.1f} kHz de error "
                        f"de reloj = {ppm:+.1f} ppm). Para comprobarlo exacto: SSB_ARFCN=<dl_ssb_arfcn del log del gNB>")
        if ssb["period_ms"]:
            if cfg["ssb_period_ms"]:
                chk("PASS" if abs(ssb["period_ms"] - cfg["ssb_period_ms"]) < 1 else "FAIL",
                    f"periodo de ráfaga SSB {ssb['period_ms']:.1f} ms, configurado {cfg['ssb_period_ms']} ms")
            else:
                chk("INFO", f"periodo de ráfaga SSB {ssb['period_ms']:.1f} ms ({ssb['ssb_per_burst']} SSB por ráfaga)")
        else:
            chk("WARN", "solo una ráfaga SSB en la captura: capturar más tiempo (DUR) para medir el periodo")
    lo, hi = cfg["fc_hz"] - cfg["bw_mhz"] * 5e5, cfg["fc_hz"] + cfg["bw_mhz"] * 5e5
    if band_hold:
        inside = band_hold[0] >= lo - 1e6 and band_hold[1] <= hi + 1e6
        chk("PASS" if inside else "WARN",
            f"señal ocupa {band_hold[0] / 1e6:.3f}-{band_hold[1] / 1e6:.3f} MHz "
            f"({(band_hold[1] - band_hold[0]) / 1e6:.2f} MHz, max-hold), canal configurado "
            f"{lo / 1e6:.3f}-{hi / 1e6:.3f} MHz" + ("" if inside else " -> hay energía fuera del canal"))
    chk("INFO", "sin tráfico el gNB solo emite SSB/control; para ver los "
                f"{cfg['bw_mhz']:g} MHz llenos, capturar mientras el UE descarga (iperf3 -R)")

    # plots
    plt = plt_mod()
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.plot(f / 1e6, psd_db, lw=0.8, label="promedio (Welch)")
    ax.plot(f / 1e6, hold_db, lw=0.6, alpha=0.7, label="max-hold")
    ax.axvspan(lo / 1e6, hi / 1e6, color="tab:green", alpha=0.12, label="canal configurado")
    if ssb:
        fs_ = det["f_ss"] + det["offset_hz"]
        ax.axvspan((fs_ - 120 * cfg["ssb_scs_khz"] * 1e3) / 1e6, (fs_ + 120 * cfg["ssb_scs_khz"] * 1e3) / 1e6,
                   color="tab:red", alpha=0.15, label="SSB detectado")
    ax.set(xlabel="Frecuencia (MHz)", ylabel="dB/Hz (relativo)", title="Espectro de la captura")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "espectro.png"), dpi=120)
    plt.close(fig)

    nfft = 512
    seg = x[: int(min(x.size, 0.1 * fs))]
    ff, tt, sxx = signal.spectrogram(seg, fs, nperseg=nfft, noverlap=nfft // 2, return_onesided=False)
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.pcolormesh(tt * 1e3, (np.fft.fftshift(ff) + fc) / 1e6, db(np.fft.fftshift(sxx, axes=0)), shading="auto")
    ax.set(xlabel="Tiempo (ms)", ylabel="Frecuencia (MHz)", title="Espectrograma (primeros 100 ms)")
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "espectrograma.png"), dpi=120)
    plt.close(fig)

    if ssb:
        t, m = ssb["metric_curve"]
        fig, ax = plt.subplots(figsize=(10, 3))
        ax.plot(t, m, lw=0.6)
        ax.axhline(CORR_THRESHOLD, color="gray", ls=":")
        ax.set(xlabel="Tiempo (ms)", ylabel="correlación PSS", ylim=(0, 1.05),
               title=f"Detecciones del SSB (PCI {ssb['pci']})")
        fig.tight_layout()
        fig.savefig(os.path.join(out_dir, "ssb_pss.png"), dpi=120)
        plt.close(fig)

    report = {
        "capture": os.path.basename(path), "fc_hz": fc, "fs_hz": fs, "level_dbfs": rms_dbfs, "clipped": clip,
        "config": {k: v for k, v in cfg.items()},
        "occupied_avg_hz": band_avg, "occupied_maxhold_hz": band_hold,
        "ssb": None if not ssb else {k: v for k, v in ssb.items() if k != "metric_curve"} | {
            "nid2": det["nid2"], "raster_hz": det["f_ss"], "offset_hz": det["offset_hz"],
            "metric": det["metric"]},
        "checks": checks,
    }
    with open(os.path.join(out_dir, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2, default=float)
    with open(os.path.join(out_dir, "report.md"), "w") as fh:
        fh.write(f"# Validación RF: {os.path.basename(path)}\n\n")
        fh.write(f"Config gNB: `{cfg['source']}` (dl_arfcn {cfg['dl_arfcn']}, {cfg['bw_mhz']:g} MHz, "
                 f"SCS {cfg['scs_khz']} kHz, PCI {cfg['pci']}). Captura a {fc / 1e6:.4f} MHz, "
                 f"{fs / 1e6:.2f} Msps.\n\n| Resultado | Detalle |\n|---|---|\n")
        for s, txt in checks:
            fh.write(f"| {s} | {txt} |\n")
        fh.write("\nFiguras: `espectro.png`, `espectrograma.png`" + (", `ssb_pss.png`" if ssb else "") + "\n")
    return checks, report


def print_checks(checks):
    color = {"PASS": "\033[32m✔", "FAIL": "\033[31m✘", "WARN": "\033[33m!", "INFO": "\033[36mi"}
    tty = sys.stdout.isatty()
    for s, txt in checks:
        mark = color[s] if tty else s
        print(f"  {mark} {txt}" + ("\033[0m" if tty else ""))


def cmd_analyze(args):
    cfg = resolve_config(args)
    meta_path = os.path.splitext(args.iq)[0] + ".json"
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    fc = float(args.fc or meta.get("fc_hz") or cfg["fc_hz"])
    fs = float(args.fs or meta.get("fs_hz") or cfg["fs_hz"])
    out = os.path.dirname(os.path.abspath(args.iq))
    checks, _ = analyze(args.iq, cfg, fc, fs, out)
    print_checks(checks)
    print(f"  report: {os.path.relpath(os.path.join(out, 'report.md'), ROOT)}")
    return 1 if any(s == "FAIL" for s, _ in checks) else 0


# --------------------------------------------------------------------------------------------
# Self test: synthetic NR downlink through a "HackRF" (int8, noise, clock error)
# --------------------------------------------------------------------------------------------
def synth_capture(path, fs, fc, f_ssb, pci, scs, bw_mhz, period_ms=20, dur_s=0.1, offset_hz=17e3,
                  snr_db=15, seed=1):
    rng = np.random.default_rng(seed)
    nfft = int(round(fs / scs))
    ncp, ncp_long = int(round(144 / 2048 * nfft)), int(round(160 / 2048 * nfft))
    sym_per_slot = 14
    slots = int(round(dur_s * 1e3 * scs / 15e3))
    nprb = int(0.9 * bw_mhz * 1e6 / (12 * scs))     # ~ TS 38.101-1 transmission bandwidth
    data_bins = np.arange(-6 * nprb, 6 * nprb)
    ssb_shift = int(round((f_ssb - fc) / scs))
    nid1, nid2 = pci // 3, pci % 3
    ssb_syms = {2, 8, 16, 22}                          # Case A (15 kHz) / C (30 kHz): 4 SSBs in 2 slots
    period_slots = int(period_ms * scs / 15e3)
    qpsk = lambda n: (rng.choice([-1, 1], n) + 1j * rng.choice([-1, 1], n)) / np.sqrt(2)  # noqa: E731
    out = []
    for s in range(slots):
        for l in range(sym_per_slot):
            grid = np.zeros(nfft, complex)
            if s % 4 == 0:                                 # some PDSCH load to show the channel
                grid[data_bins % nfft] = 0.3 * qpsk(data_bins.size)
            sym_in_burst = (s % period_slots) * sym_per_slot + l
            if s % period_slots < 2:
                for first in ssb_syms:
                    k = None
                    if sym_in_burst == first:
                        k = pss(nid2)
                    elif sym_in_burst == first + 2:
                        k = sss(nid1, nid2)
                    elif sym_in_burst in (first + 1, first + 3):
                        k = qpsk(127)
                    if k is not None:
                        grid[(SSB_K + ssb_shift) % nfft] = k
            sym = np.fft.ifft(grid) * np.sqrt(nfft)
            cp = ncp_long if (l % 7 == 0 if scs == 15e3 else l == 0) else ncp   # long CP every 0.5 ms
            out.append(np.concatenate([sym[-cp:], sym]))
    x = np.concatenate(out)
    x *= np.exp(2j * np.pi * offset_hz / fs * np.arange(x.size))
    p = np.mean(np.abs(x) ** 2)
    x += np.sqrt(p / 10 ** (snr_db / 10) / 2) * (rng.standard_normal(x.size) + 1j * rng.standard_normal(x.size))
    x *= 0.15 / np.sqrt(np.mean(np.abs(x) ** 2))      # ~ -16 dBFS, like a sane HackRF gain setting
    iq = np.empty(2 * x.size, np.int8)
    iq[0::2] = np.clip(np.round(x.real * 128), -128, 127)
    iq[1::2] = np.clip(np.round(x.imag * 128), -128, 127)
    iq.tofile(path)


def cmd_selftest(args):
    out = args.out or os.path.join(ROOT, "results", "rf", "selftest")
    os.makedirs(out, exist_ok=True)
    cases = [  # (description, pci, dl_arfcn, ssb_arfcn, bw, scs kHz, known SSB?)
        ("perfil del repo n3 FDD 10 MHz 15 kHz, PCI 1, SSB conocido", 1, 368500, 368410, 10, 15, True),
        ("n3 10 MHz, PCI 500, SSB buscado en el raster", 500, 368500, 368410, 10, 15, False),
        ("n78 TDD 3.5 GHz 10 MHz 30 kHz, PCI 1, SSB buscado en el raster", 1, 632628, 632640, 10, 30, False),
    ]
    failed = 0
    for desc, pci, dl, ssb_arfcn, bw, scs_khz, known in cases:
        print(f"==> selftest: {desc}")
        fs, fc, f_ssb = 15.36e6, arfcn_to_hz(dl), arfcn_to_hz(ssb_arfcn)
        path = os.path.join(out, f"synth_pci{pci}.iq")
        t0 = time.time()
        synth_capture(path, fs, fc, f_ssb, pci, scs_khz * 1e3, bw)
        cfg = {"dl_arfcn": dl, "band": None, "bw_mhz": bw, "scs_khz": scs_khz, "ssb_scs_khz": scs_khz, "pci": pci,
               "ssb_period_ms": 20, "source": "sintético", "ssb_arfcn": ssb_arfcn if known else None,
               "fc_hz": fc, "ssb_hz": f_ssb if known else None, "fs_hz": fs}
        checks, rep = analyze(path, cfg, fc, fs, out, log=lambda *_: None)
        print_checks(checks)
        ok = (rep["ssb"] and rep["ssb"]["pci"] == pci and abs(rep["ssb"]["period_ms"] - 20) < 1
              and abs(rep["ssb"]["raster_hz"] + rep["ssb"]["offset_hz"] - f_ssb - 17e3) < 2e3
              and not any(s == "FAIL" for s, _ in checks))
        print(f"  {'OK' if ok else 'FALLÓ'} ({time.time() - t0:.1f} s)")
        failed += not ok
        os.remove(path)
    print("RESULT: selftest " + ("passed" if not failed else f"{failed} case(s) failed"))
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--gnb-config", help="gNB YAML used with the USRP (default: GNB_CFG or repo profile)")
        p.add_argument("--dl-arfcn", type=int)
        p.add_argument("--bw", type=float, help="channel bandwidth (MHz)")
        p.add_argument("--scs", dest="scs_khz", type=int, help="common SCS (kHz)")
        p.add_argument("--ssb-scs", type=int, help="SSB SCS (kHz), default = common SCS")
        p.add_argument("--pci", type=int)
        p.add_argument("--ssb-arfcn", type=int, help="dl_ssb_arfcn printed by the gNB at startup")
        return p

    common(sub.add_parser("params"))
    p = common(sub.add_parser("sweep"))
    p.add_argument("csv")
    p = common(sub.add_parser("analyze"))
    p.add_argument("iq")
    p.add_argument("--fc", type=float, help="tuning frequency (Hz), default from <capture>.json")
    p.add_argument("--fs", type=float, help="sample rate (Hz), default from <capture>.json")
    p = sub.add_parser("selftest")
    p.add_argument("--out")
    args = ap.parse_args()
    return {"params": cmd_params, "sweep": cmd_sweep, "analyze": cmd_analyze, "selftest": cmd_selftest}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
