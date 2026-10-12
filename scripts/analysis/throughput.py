#!/usr/bin/env python3
"""Coding and performance analysis for the 5G SA lab.

Theory (3GPP formulas, no network needed):
  - MCS/CQI tables (TS 38.214 5.1.3.1-1/-2, 5.2.2.1-2), spectral efficiency vs Shannon.
  - TBS (TS 38.214 5.1.3.2), LDPC base graph + segmentation (TS 38.212 5.2.2, 6.2.2/7.2.2),
    Polar code size and rate matching (TS 38.212 5.3.1, 5.4.1), peak rate (TS 38.306 4.1.2).
Measurements (whatever exists under results/raw/):
  - bler/      link-level BLER/WER from scripts/analysis/bler.sh
  - tbs_bw*/   real scheduler grants (scripts/measure.sh tbs) -> validates our TBS function
  - mcs*_bw*/  fixed-MCS sweep, bw*/ bandwidth sweep (scripts/measure.sh mcs|bw)
Writes CSVs, PNGs and resumen.md to results/analysis/.

Usage: python3 scripts/analysis/throughput.py
"""
import csv
import glob
import json
import math
import os
import re
import statistics as st

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RAW = os.path.join(ROOT, "results", "raw")
OUT = os.path.join(ROOT, "results", "analysis")

# --------------------------------------------------------------------------------------------
# 3GPP tables
# --------------------------------------------------------------------------------------------
# TS 38.214 Table 5.1.3.1-1 (MCS index table 1, up to 64QAM): (Qm, R x 1024). Used by PDSCH and
# by PUSCH without transform precoding (TS 38.214 6.1.4.1).
MCS_64QAM = [(2, 120), (2, 157), (2, 193), (2, 251), (2, 308), (2, 379), (2, 449), (2, 526), (2, 602),
             (2, 679), (4, 340), (4, 378), (4, 434), (4, 490), (4, 553), (4, 616), (4, 658), (6, 438),
             (6, 466), (6, 517), (6, 567), (6, 616), (6, 666), (6, 719), (6, 772), (6, 822), (6, 873),
             (6, 910), (6, 948)]
# TS 38.214 Table 5.1.3.1-2 (MCS index table 2, up to 256QAM), for comparison only (srsUE: 64QAM).
MCS_256QAM = [(2, 120), (2, 193), (2, 308), (2, 449), (2, 602), (4, 378), (4, 434), (4, 490), (4, 553),
              (4, 616), (4, 658), (6, 466), (6, 517), (6, 567), (6, 616), (6, 666), (6, 719), (6, 772),
              (6, 822), (6, 873), (8, 682.5), (8, 711), (8, 754), (8, 797), (8, 841), (8, 885),
              (8, 916.5), (8, 948)]
# TS 38.214 Table 5.2.2.1-2 (4-bit CQI table 1): index 1..15 -> (Qm, R x 1024)
CQI_TABLE1 = {1: (2, 78), 2: (2, 120), 3: (2, 193), 4: (2, 308), 5: (2, 449), 6: (2, 602), 7: (4, 378),
              8: (4, 490), 9: (4, 616), 10: (6, 466), 11: (6, 567), 12: (6, 666), 13: (6, 772),
              14: (6, 873), 15: (6, 948)}
# TS 38.214 Table 5.1.3.2-1: TBS for N_info <= 3824
TBS_TABLE = [24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 144, 152, 160, 168, 176,
             184, 192, 208, 224, 240, 256, 272, 288, 304, 320, 336, 352, 368, 384, 408, 432, 456, 480,
             504, 528, 552, 576, 608, 640, 672, 704, 736, 768, 808, 848, 888, 928, 984, 1032, 1064,
             1128, 1160, 1192, 1224, 1256, 1288, 1320, 1352, 1416, 1480, 1544, 1608, 1672, 1736, 1800,
             1864, 1928, 2024, 2088, 2152, 2216, 2280, 2408, 2472, 2536, 2600, 2664, 2728, 2792, 2856,
             2976, 3104, 3240, 3368, 3496, 3624, 3752, 3824]
# TS 38.212 Table 5.3.2-1: LDPC lifting sizes Zc
LIFTING = sorted({a * 2 ** j for a in (2, 3, 5, 7, 9, 11, 13, 15) for j in range(8) if a * 2 ** j <= 384})
MOD = {2: "QPSK", 4: "16QAM", 6: "64QAM", 8: "256QAM"}

# Our cell (scripts/gen-radio-configs.sh): BW -> (N_PRB, CORESET#0 size in RB). DCI 1_0 in the common
# search space sizes the PDSCH allocation by CORESET#0 (TS 38.212 7.3.1.2.1), so DL PRBs = min of both.
BW_PROFILES = {10: (52, 48), 15: (79, 48), 20: (106, 96)}
SYMB_PDSCH, SYMB_PUSCH, DMRS_RE = 13, 14, 36   # PDSCH symb 1-13 (CORESET 1 symb); 3 DMRS symb x 12 RE


# --------------------------------------------------------------------------------------------
# Formulas
# --------------------------------------------------------------------------------------------
def tbs_bits(n_prb, mcs, n_symb=SYMB_PDSCH, n_dmrs=DMRS_RE, n_oh=0, table=MCS_64QAM, layers=1):
    """Transport block size, TS 38.214 5.1.3.2."""
    qm, r1024 = table[mcs]
    r = r1024 / 1024
    n_re_prime = 12 * n_symb - n_dmrs - n_oh
    n_re = min(156, n_re_prime) * n_prb
    n_info = n_re * r * qm * layers
    if n_info <= 3824:
        n = max(3, math.floor(math.log2(n_info)) - 6)
        n_info_p = max(24, 2 ** n * math.floor(n_info / 2 ** n))
        return next(t for t in TBS_TABLE if t >= n_info_p)
    n = math.floor(math.log2(n_info - 24)) - 5
    n_info_p = max(3840, 2 ** n * round((n_info - 24) / 2 ** n))
    if r <= 0.25:
        c = math.ceil((n_info_p + 24) / 3816)
        return 8 * c * math.ceil((n_info_p + 24) / (8 * c)) - 24
    if n_info_p > 8424:
        c = math.ceil((n_info_p + 24) / 8424)
        return 8 * c * math.ceil((n_info_p + 24) / (8 * c)) - 24
    return 8 * math.ceil((n_info_p + 24) / 8) - 24


def ldpc(a, r, g_bits):
    """Base graph + code block segmentation for a TB of A bits at rate R (TS 38.212 7.2.2, 5.2.2).
    g_bits: coded bits available (N_RE x Qm) to derive the per-block rate-matching length E."""
    bg = 2 if (a <= 292 or (a <= 3824 and r <= 0.67) or r <= 0.25) else 1
    l_tb = 24 if a > 3824 else 16
    b = a + l_tb
    kcb = 8448 if bg == 1 else 3840
    if b <= kcb:
        c, b_p = 1, b
    else:
        c = math.ceil(b / (kcb - 24))
        b_p = b + 24 * c
    k_p = b_p // c
    if bg == 1:
        kb = 22
    else:
        kb = 10 if b > 640 else 9 if b > 560 else 8 if b > 192 else 6
    zc = next(z for z in LIFTING if kb * z >= k_p)
    k = (22 if bg == 1 else 10) * zc
    n = (66 if bg == 1 else 50) * zc
    e = g_bits / c
    return {"bg": bg, "crc_tb": l_tb, "C": c, "K_prime": k_p, "Zc": zc, "K": k, "filler": k - k_p, "N": n,
            "mother_rate": round(k / n, 3), "E_per_cb": round(e), "rate_per_cb": round(k_p / e, 3)}


def polar(k, e, nmax=9):
    """Polar mother code length and rate-matching mode (TS 38.212 5.3.1, 5.4.1.1)."""
    n1 = math.ceil(math.log2(e))
    if e <= (9 / 8) * 2 ** (n1 - 1) and k / e < 9 / 16:
        n1 -= 1
    n2 = math.ceil(math.log2(k / (1 / 8)))
    n = max(min(n1, n2, nmax), 5)
    big_n = 2 ** n
    mode = "repetición" if e >= big_n else ("puncturing" if k / e <= 7 / 16 else "shortening")
    return {"N": big_n, "mode": mode, "rate": round(k / e, 3)}


def peak_38306(n_prb, qm=6, rmax=948 / 1024, mu=0, oh=0.14, layers=1, f=1.0):
    """Approximate max data rate in Mbit/s, TS 38.306 4.1.2 (one carrier)."""
    ts = 1e-3 / (14 * 2 ** mu)
    return 1e-6 * layers * qm * f * rmax * (n_prb * 12) / ts * (1 - oh)


def shannon_snr_db(se):
    return 10 * math.log10(2 ** se - 1)


# --------------------------------------------------------------------------------------------
# Raw data parsers
# --------------------------------------------------------------------------------------------
def eng(s):
    """'29M' -> 29e6, '189k' -> 189e3, '0' -> 0."""
    m = re.fullmatch(r"([0-9.]+)([kMG]?)", s)
    if not m:
        return float("nan")
    return float(m.group(1)) * {"": 1, "k": 1e3, "M": 1e6, "G": 1e9}[m.group(2)]


def gnb_rows(path):
    """gNB console metric rows -> list of dicts (DL and UL per second)."""
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path):
        parts = line.split("|")
        if len(parts) < 3:
            continue
        dl, ul = parts[1].split(), parts[2].split()
        try:
            rows.append({"cqi": float(dl[0]), "dl_mcs": int(dl[2]), "dl_brate": eng(dl[3]),
                         "dl_ok": int(dl[4]), "dl_nok": int(dl[5]), "pusch_snr": float(ul[0]),
                         "ul_mcs": int(ul[2]), "ul_brate": eng(ul[3]), "ul_ok": int(ul[4]),
                         "ul_nok": int(ul[5])})
        except (ValueError, IndexError):
            continue
    return rows


def busy(rows, key):
    """Rows of the loaded seconds only (>=50% of the max bit rate), so ramp-up/down is excluded."""
    if not rows:
        return []
    top = max(r[key] for r in rows)
    return [r for r in rows if top > 0 and r[key] >= 0.5 * top]


def iperf(path):
    if not os.path.exists(path):
        return None
    try:
        j = json.load(open(path))
        end = j["end"]
    except (ValueError, KeyError):
        return None
    if "sum_received" in end:   # TCP
        return {"mbps": end["sum_received"]["bits_per_second"] / 1e6,
                "retrans": end["sum_sent"].get("retransmits", 0)}
    s = end["sum"]              # UDP
    return {"mbps": s["bits_per_second"] / 1e6 * (1 - s["lost_percent"] / 100),
            "jitter_ms": s["jitter_ms"], "lost_pct": s["lost_percent"], "sent_mbps": s["bits_per_second"] / 1e6}


def ping(path):
    if not os.path.exists(path):
        return []
    return [float(x) for x in re.findall(r"time=([0-9.]+) ms", open(path).read())]


def stats_csv(path):
    """docker stats samples -> {container: (mean cpu %, mean mem MiB)}"""
    acc = {}
    if not os.path.exists(path):
        return {}
    for line in open(path):
        p = line.strip().split(",")
        if len(p) < 3 or not p[1].endswith("%"):
            continue
        mem = p[2].split("/")[0].strip()
        m = re.match(r"([0-9.]+)\s*([KMG]i?B)", mem)
        mib = float(m.group(1)) * {"KiB": 1 / 1024, "MiB": 1, "GiB": 1024, "kB": 1 / 1000, "MB": 1,
                                   "GB": 1000}.get(m.group(2), 1) if m else float("nan")
        acc.setdefault(p[0], []).append((float(p[1][:-1]), mib))
    return {k: (st.mean(c for c, _ in v), st.mean(m for _, m in v)) for k, v in acc.items()}


def meta(d):
    out = {}
    if os.path.exists(os.path.join(d, "meta.env")):
        for line in open(os.path.join(d, "meta.env")):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                out[k] = v
    return out


def ms(x):
    return f"{x:.1f}"


def write_csv(name, header, rows):
    with open(os.path.join(OUT, name), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def md_table(header, rows):
    s = "| " + " | ".join(header) + " |\n|" + "---|" * len(header) + "\n"
    for r in rows:
        s += "| " + " | ".join(str(x) for x in r) + " |\n"
    return s


# --------------------------------------------------------------------------------------------
# Sections
# --------------------------------------------------------------------------------------------
def section_tables(md):
    md.append("## 1. Tablas MCS/CQI y eficiencia espectral\n")
    rows = []
    for i, (qm, r) in enumerate(MCS_64QAM):
        se = qm * r / 1024
        rows.append([i, MOD[qm], qm, r, round(r / 1024, 4), round(se, 4), round(shannon_snr_db(se), 2)])
    write_csv("mcs_tabla1_64qam.csv", ["mcs", "mod", "Qm", "Rx1024", "R", "SE_bits_por_RE",
                                       "SNR_min_shannon_dB"], rows)
    md.append("Tabla MCS 1 (TS 38.214 5.1.3.1-1). SE = Qm·R; SNR mínima de Shannon = 2^SE − 1.\n\n")
    md.append(md_table(["MCS", "Mod", "Qm", "R×1024", "SE (bit/RE)", "SNR Shannon (dB)"],
                       [[r[0], r[1], r[2], r[3], r[5], r[6]] for r in rows]))
    rows2 = [[i, MOD[q], q, r, round(q * r / 1024, 4)] for i, (q, r) in enumerate(MCS_256QAM)]
    write_csv("mcs_tabla2_256qam.csv", ["mcs", "mod", "Qm", "Rx1024", "SE"], rows2)
    rows3 = [[c, MOD[q], q, r, round(q * r / 1024, 4)] for c, (q, r) in CQI_TABLE1.items()]
    write_csv("cqi_tabla1.csv", ["cqi", "mod", "Qm", "Rx1024", "SE"], rows3)

    fig, ax = plt.subplots(figsize=(8, 4.2))
    ax.plot(range(29), [q * r / 1024 for q, r in MCS_64QAM], "o-", label="Tabla 1 (64QAM) — la nuestra")
    ax.plot(range(28), [q * r / 1024 for q, r in MCS_256QAM], "s--", alpha=.7, label="Tabla 2 (256QAM)")
    ax.set_xlabel("Índice MCS"); ax.set_ylabel("Eficiencia espectral Qm·R (bit/RE)")
    ax.set_title("Eficiencia por MCS (TS 38.214 tablas 5.1.3.1-1 y -2)"); ax.grid(alpha=.3); ax.legend()
    fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig1_mcs_eficiencia.png"), dpi=130); plt.close(fig)


def section_tbs(md):
    md.append("\n## 2. TBS, LDPC y velocidad teórica para nuestra celda\n")
    md.append("Supuestos (verificados con el log del scheduler, sección 3): PDSCH en símbolos 1–13 (13), "
              "PUSCH 0–13 (14), DMRS tipo A pos2 + 2 adicionales = 3 símbolos × 12 RE, sin xOverhead, "
              "1 capa. PRB de DL limitados por CORESET#0 (DCI 1_0 en espacio común).\n\n")
    rows = []
    for bw, (nprb, coreset) in BW_PROFILES.items():
        dl_prb = min(nprb, coreset)
        ul_prb = nprb - 6          # PUCCH resources at both band edges (3 PRB each, seen at 10 MHz)
        for mcs in range(29):
            qm, r = MCS_64QAM[mcs]
            tdl = tbs_bits(dl_prb, mcs, SYMB_PDSCH)
            tul = tbs_bits(ul_prb, mcs, SYMB_PUSCH)
            rows.append([bw, mcs, dl_prb, tdl, round(tdl * 1000 / 1e6, 2), ul_prb, tul, round(tul * 1000 / 1e6, 2)])
    write_csv("tbs_por_mcs.csv", ["bw_mhz", "mcs", "dl_prb", "tbs_dl_bits", "dl_mbps_1000slots", "ul_prb",
                                  "tbs_ul_bits", "ul_mbps_1000slots"], rows)

    peak = []
    for bw, (nprb, coreset) in BW_PROFILES.items():
        dl_prb, ul_prb = min(nprb, coreset), nprb - 6
        peak.append([bw, nprb, round(peak_38306(nprb), 1), round(peak_38306(nprb, oh=0.08), 1), dl_prb,
                     round(tbs_bits(dl_prb, 28) * 1000 / 1e6, 1), ul_prb,
                     round(tbs_bits(ul_prb, 28, SYMB_PUSCH) * 1000 / 1e6, 1)])
    write_csv("pico_teorico.csv", ["bw_mhz", "n_prb", "ts38306_dl_mbps", "ts38306_ul_mbps", "dl_prb_reales",
                                   "tbs_dl_mcs28_mbps", "ul_prb_reales", "tbs_ul_mcs28_mbps"], peak)
    md.append("Velocidad máxima: fórmula TS 38.306 §4.1.2 (v=1, Qm=6, f=1, Rmax=948/1024, μ=0, OH 14 % DL "
              "/ 8 % UL) vs TBS real a MCS 28 × 1000 slots/s:\n\n")
    md.append(md_table(["BW", "N_PRB", "38.306 DL", "38.306 UL", "PRB DL", "TBS DL MCS28", "PRB UL",
                        "TBS UL MCS28"], [[f"{p[0]} MHz", p[1], f"{p[2]} Mb/s", f"{p[3]} Mb/s", p[4],
                                           f"{p[5]} Mb/s", p[6], f"{p[7]} Mb/s"] for p in peak]))

    md.append("\nLDPC para algunos MCS con 48 PRB (DL 10 MHz). G = N_RE·Qm bits codificados:\n\n")
    lrows = []
    n_re = min(156, 12 * SYMB_PDSCH - DMRS_RE) * 48
    for mcs in (0, 3, 9, 10, 17, 28):
        qm, r = MCS_64QAM[mcs]
        a = tbs_bits(48, mcs)
        p = ldpc(a, r / 1024, n_re * qm)
        lrows.append([mcs, MOD[qm], round(r / 1024, 3), a, f"BG{p['bg']}", p["C"], p["K_prime"], p["Zc"], p["K"],
                      p["filler"], p["N"], p["E_per_cb"], p["rate_per_cb"]])
    # A small grant: the 1-PRB control-plane grants seen in the scheduler log
    for prb, mcs in ((1, 27), (42, 3)):
        qm, r = MCS_64QAM[mcs]
        a = tbs_bits(prb, mcs)
        nre = min(156, 12 * SYMB_PDSCH - DMRS_RE) * prb
        p = ldpc(a, r / 1024, nre * qm)
        lrows.append([f"{mcs} ({prb} PRB)", MOD[qm], round(r / 1024, 3), a, f"BG{p['bg']}", p["C"], p["K_prime"],
                      p["Zc"], p["K"], p["filler"], p["N"], p["E_per_cb"], p["rate_per_cb"]])
    hdr = ["MCS", "Mod", "R", "TBS A", "BG", "C", "K'", "Zc", "K", "relleno", "N", "E/CB", "tasa/CB"]
    write_csv("ldpc_segmentacion.csv", hdr, lrows)
    md.append(md_table(hdr, lrows))

    md.append("\nPolar (control): K = carga + CRC 24, E = bits tras rate matching (PDCCH: 108·AL).\n\n")
    prow = []
    for name, k, e in (("PBCH (MIB 32 b)", 56, 864), ("DCI 1_0 AL1", 63, 108), ("DCI 1_0 AL2", 63, 216),
                       ("DCI 1_0 AL4", 63, 432), ("DCI 1_0 AL8", 63, 864)):
        p = polar(k, e)
        prow.append([name, k, e, p["N"], p["rate"], p["mode"]])
    write_csv("polar.csv", ["caso", "K", "E", "N", "K/E", "rate_matching"], prow)
    md.append(md_table(["Caso", "K", "E", "N", "K/E", "Rate matching"], prow))


def section_tbs_validation(md):
    files = sorted(glob.glob(os.path.join(RAW, "tbs_bw*", "p*sch_mcs*.txt")))
    if not files:
        return
    md.append("\n## 3. Validación: TBS calculado vs TBS que usa el scheduler del gNB\n")
    rows, ok, tot, reduced, shapes = [], 0, 0, 0, {}
    for f in files:
        bw = re.search(r"tbs_bw(\d+)", f).group(1)
        ch = "PDSCH" if "pdsch" in os.path.basename(f) else "PUSCH"
        for line in open(f):
            m = re.search(r"^\s*(\d+) .*rb=\[(\d+)\.\.(\d+)\) symb=\[(\d+)\.\.(\d+)\) tbs=(\d+).*mcs=(\d+)", line)
            if not m:
                continue
            cnt, rb0, rb1, s0, s1, tbs_b, mcs = map(int, m.groups())
            nprb, nsym = rb1 - rb0, s1 - s0
            if nsym < 12:
                continue   # only full-slot grants (3 DMRS symbols) are modelled here
            calc = tbs_bits(nprb, mcs, nsym) // 8
            used = mcs
            if calc != tbs_b and ch == "PUSCH":
                # The PUSCH log line has no MCS; srsRAN lowers it while the effective code rate > 0.95
                # (mcs_tbs_calculator.cpp, TS 38.214 5.1.3.1/6.1.4.1). Find the MCS that explains the TBS.
                used = next((x for x in range(mcs - 1, -1, -1) if tbs_bits(nprb, x, nsym) // 8 == tbs_b), mcs)
                calc = tbs_bits(nprb, used, nsym) // 8
            key = (bw, ch, mcs, used, nprb, nsym, tbs_b, calc)
            shapes[key] = shapes.get(key, 0) + cnt   # same grant can appear with different UCI/OLLA fields
    for (bw, ch, mcs, used, nprb, nsym, tbs_b, calc), cnt in shapes.items():
        match = calc == tbs_b
        ok += match; tot += 1; reduced += (used != mcs)
        rows.append([bw, ch, mcs, used, nprb, nsym, cnt, tbs_b, calc, "sí" if match else "NO"])
    rows.sort(key=lambda r: (-r[6]))
    write_csv("validacion_tbs.csv", ["bw_mhz", "canal", "mcs_fijado", "mcs_usado", "prb", "simbolos", "veces",
                                     "tbs_log_bytes", "tbs_calc_bytes", "coincide"], rows)
    md.append(f"{ok - reduced}/{tot - reduced} asignaciones distintas (≥ 12 símbolos) coinciden byte a byte con "
              "TS 38.214 §5.1.3.2 usando el MCS del log (PDSCH) o el fijado (PUSCH). Las otras "
              f"{reduced}, todas PUSCH de 1-5 PRB, solo se explican con un MCS menor (27): el scheduler baja el "
              "MCS mientras la tasa efectiva supere 0.95 (el log de PUSCH no imprime el MCS, así que estas se "
              "infieren, no se validan). Las más frecuentes:\n\n")
    md.append(md_table(["BW", "Canal", "MCS fijado", "MCS usado", "PRB", "Símb.", "Veces", "TBS log (B)",
                        "TBS calc (B)", "¿="], rows[:14]))


def load_bler():
    curves = {}
    for f in glob.glob(os.path.join(RAW, "bler", "ldpc_mcs*.txt")):
        for line in open(f):
            p = line.split()
            if len(p) >= 6:
                curves.setdefault(int(p[0]), []).append((float(p[1]), float(p[2]), int(p[3]), int(p[4]), int(p[5])))
    for k in curves:
        curves[k].sort()
    return curves


def snr_at(curve, target):
    """SNR where BLER crosses `target`, log-linear interpolation."""
    for (s0, b0, *_), (s1, b1, *_) in zip(curve, curve[1:]):
        if b0 >= target > b1:
            lb0 = math.log10(max(b0, 1e-4)); lb1 = math.log10(max(b1, 1e-4))
            return s0 + (math.log10(target) - lb0) * (s1 - s0) / (lb1 - lb0)
    return float("nan")


def bler_interp(curve, snr):
    if snr <= curve[0][0]:
        return curve[0][1]
    if snr >= curve[-1][0]:
        return curve[-1][1]
    for (s0, b0, *_), (s1, b1, *_) in zip(curve, curve[1:]):
        if s0 <= snr <= s1:
            lb0, lb1 = math.log10(max(b0, 1e-5)), math.log10(max(b1, 1e-5))
            v = 10 ** (lb0 + (snr - s0) * (lb1 - lb0) / (s1 - s0))
            return 0.0 if v <= 1e-5 else v
    return 0.0


def section_bler(md):
    curves = load_bler()
    if not curves:
        return
    md.append("\n## 4. Canal: BLER vs SNR (AWGN, PHY de srsRAN 4G) y elección de MCS\n")
    md.append("Simulación a nivel de enlace con `pusch_nr_bler_test` (48 PRB × 14 símbolos, LDPC + QAM + "
              "DMRS, estimación de canal perfecta). SNR = Es/N0 por RE. Umbral de trabajo: BLER 10 % "
              "(objetivo típico de la 1.ª transmisión con HARQ).\n\n")
    rows = []
    n_re = 6336  # 48 PRB x (14*12 - 36)
    for m in sorted(curves):
        qm, r = MCS_64QAM[m]
        se = qm * r / 1024
        s10 = snr_at(curves[m], 0.1)
        s1 = snr_at(curves[m], 0.01)
        tbs = curves[m][0][4]
        rows.append([m, MOD[qm], round(se, 3), round(tbs / n_re, 3), round(shannon_snr_db(se), 2),
                     round(s10, 2), round(s1, 2), round(s10 - shannon_snr_db(se), 2)])
    write_csv("bler_umbral_snr.csv", ["mcs", "mod", "SE", "bits_por_RE_datos", "snr_shannon_dB", "snr_bler10_dB",
                                      "snr_bler1_dB", "brecha_shannon_dB"], rows)
    md.append(md_table(["MCS", "Mod", "SE", "SNR Shannon", "SNR @BLER 10 %", "SNR @BLER 1 %", "Brecha"],
                       [[r[0], r[1], r[2], f"{r[4]} dB", f"{r[5]} dB", f"{r[6]} dB", f"{r[7]} dB"]
                        for r in rows]))

    # CQI -> MCS with the same (Qm, R) -> required SNR
    crow = []
    for c, (q, r) in CQI_TABLE1.items():
        same = [i for i, x in enumerate(MCS_64QAM) if x == (q, r)]
        if same and same[0] in curves:
            crow.append([c, MOD[q], r, same[0], round(snr_at(curves[same[0]], 0.1), 1)])
        else:
            crow.append([c, MOD[q], r, "—", "—"])
    write_csv("cqi_snr.csv", ["cqi", "mod", "Rx1024", "mcs_equivalente", "snr_bler10_dB"], crow)
    md.append("\nCQI (tabla 1) → MCS con el mismo (Qm, R) → SNR necesaria para BLER 10 %:\n\n")
    md.append(md_table(["CQI", "Mod", "R×1024", "MCS equiv.", "SNR @10 %"], crow))

    # Link adaptation envelope: best MCS per SNR (max SE x (1-BLER) with BLER <= 10%)
    grid = [x / 2 for x in range(-16, 61)]
    env, best = [], []
    for snr in grid:
        cands = [(curves[m][0][4] / n_re * (1 - bler_interp(curves[m], snr)), m) for m in curves
                 if bler_interp(curves[m], snr) <= 0.1]
        v, m = max(cands) if cands else (0, None)
        env.append(v); best.append(m)
    write_csv("adaptacion_enlace.csv", ["snr_dB", "mejor_mcs", "bits_por_RE"],
              [[s, b if b is not None else "", round(v, 3)] for s, v, b in zip(grid, env, best)])

    fig, ax = plt.subplots(figsize=(9, 5))
    cmap = plt.get_cmap("viridis")
    for m in sorted(curves):
        xs = [p[0] for p in curves[m]]; ys = [max(p[1], 1e-4) for p in curves[m]]
        ax.semilogy(xs, ys, "-", color=cmap(m / 28), lw=1.3, label=f"MCS {m}" if m % 4 == 0 or m == 28 else None)
    ax.axhline(0.1, color="r", ls="--", lw=1, label="BLER 10 %")
    ax.set_ylim(1e-3, 1.1); ax.set_xlabel("SNR por RE (dB)"); ax.set_ylabel("BLER (1.ª transmisión)")
    ax.set_title("LDPC + QAM en AWGN: BLER vs SNR para los 29 MCS (tabla 64QAM)")
    ax.grid(alpha=.3, which="both"); ax.legend(ncol=2, fontsize=8)
    fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig2_bler_ldpc.png"), dpi=130); plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 5))
    sx = [x / 10 for x in range(-100, 301)]
    ax.plot(sx, [math.log2(1 + 10 ** (s / 10)) for s in sx], "k-", label="Shannon log2(1+SNR)")
    ax.plot(grid, env, "b-", lw=2, label="srsRAN LDPC+QAM: mejor MCS con BLER ≤ 10 %")
    ax.plot([r[5] for r in rows], [r[3] for r in rows], "o", color="tab:orange", ms=4,
            label="cada MCS en su SNR de BLER 10 %")
    ax.annotate("canal ZMQ: SNR PUSCH ≈ 65 dB (fuera de escala) → MCS 28", xy=(29.5, 5.5), xytext=(10, 7.2),
                fontsize=8, color="g", arrowprops=dict(arrowstyle="->", color="g"))
    ax.set_xlim(-10, 30); ax.set_ylim(0, 8); ax.set_xlabel("SNR por RE (dB)"); ax.set_ylabel("bit/RE")
    ax.set_title("Eficiencia alcanzable vs límite de Shannon"); ax.grid(alpha=.3); ax.legend(loc="upper left")
    fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig3_shannon_adaptacion.png"), dpi=130); plt.close(fig)

    # Polar
    pol = {}
    for f in glob.glob(os.path.join(RAW, "bler", "polar_*.txt")):
        for line in open(f):
            p = line.split()
            if len(p) >= 5:
                pol.setdefault(p[0], []).append((float(p[3]), float(p[4])))
    if pol:
        fig, ax = plt.subplots(figsize=(8, 4.5))
        prow = []
        for name in ("pbch", "dci_al2", "dci_al4", "dci_al8"):
            if name not in pol:
                continue
            c = sorted(pol[name])
            ax.semilogy([x for x, _ in c], [max(y, 1e-5) for _, y in c], "o-", ms=3, label=name.upper().replace("_", " "))
            prow.append([name, round(snr_at([(s, b, 0, 0, 0) for s, b in c], 0.01), 2)])
        ax.axhline(0.01, color="r", ls="--", lw=1, label="WER 1 %")
        ax.set_ylim(1e-5, 1.1); ax.set_xlabel("SNR por dimensión ≈ Es/N0 de QPSK (dB)"); ax.set_ylabel("WER")
        ax.set_title("Polar (control) en AWGN: PBCH y DCI 1_0 según nivel de agregación")
        ax.grid(alpha=.3, which="both"); ax.legend()
        fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig4_polar.png"), dpi=130); plt.close(fig)
        write_csv("polar_umbral.csv", ["caso", "snr_wer1pct_dB"], prow)
        md.append("\nPolar: SNR para WER 1 %: " + ", ".join(f"{n} {v} dB" for n, v in prow) + ".\n")


def section_mcs_sweep(md):
    dirs = sorted((d for d in glob.glob(os.path.join(RAW, "mcs*_bw*")) if "mcs" in meta(d)),
                  key=lambda d: int(meta(d)["mcs"]))
    if not dirs:
        return
    md.append("\n## 5. Barrido de MCS fijo (red ZMQ real)\n")
    rows = []
    for d in dirs:
        mt = meta(d); m = int(mt["mcs"]); bw = int(mt["bw_mhz"])
        nprb, coreset = BW_PROFILES[bw]
        dl, ul = iperf(os.path.join(d, "tcp_dl_1.json")), iperf(os.path.join(d, "tcp_ul_1.json"))
        gdl = busy(gnb_rows(os.path.join(d, "tcp_dl_1.gnb.txt")), "dl_brate")
        gul = busy(gnb_rows(os.path.join(d, "tcp_ul_1.gnb.txt")), "ul_brate")
        t_dl = tbs_bits(min(nprb, coreset), m) * 1000 / 1e6
        t_ul = tbs_bits(nprb - 6, m, SYMB_PUSCH) * 1000 / 1e6
        mac_dl = st.mean(r["dl_brate"] for r in gdl) / 1e6 if gdl else float("nan")
        mac_ul = st.mean(r["ul_brate"] for r in gul) / 1e6 if gul else float("nan")
        nok_dl = sum(r["dl_nok"] for r in gdl) / max(1, sum(r["dl_ok"] + r["dl_nok"] for r in gdl)) * 100 if gdl else float("nan")
        slots_dl = st.mean(r["dl_ok"] + r["dl_nok"] for r in gdl) if gdl else float("nan")
        slots_ul = st.mean(r["ul_ok"] + r["ul_nok"] for r in gul) if gul else float("nan")
        rows.append([bw, m, round(t_dl, 2), round(mac_dl, 2), round(dl["mbps"], 2) if dl else "",
                     round(t_ul, 2), round(mac_ul, 2), round(ul["mbps"], 2) if ul else "", round(nok_dl, 2),
                     round(slots_dl) if slots_dl == slots_dl else "", round(slots_ul) if slots_ul == slots_ul else ""])
    hdr = ["bw_mhz", "mcs", "tbs_dl_mbps", "mac_dl_mbps", "tcp_dl_mbps", "tbs_ul_mbps", "mac_ul_mbps",
           "tcp_ul_mbps", "dl_harq_nok_pct", "pdsch_por_s", "pusch_por_s"]
    write_csv("barrido_mcs.csv", hdr, rows)
    md.append("Teórico = TBS × 1000 slots/s; MAC = brate del gNB (segundos con carga); TCP = iperf3.\n\n")
    md.append(md_table(["BW", "MCS", "DL teórico", "DL MAC", "DL TCP", "UL teórico", "UL MAC", "UL TCP", "NOK DL",
                        "PDSCH/s", "PUSCH/s"],
                       [[f"{r[0]}", r[1], r[2], r[3], r[4], r[5], r[6], r[7], f"{r[8]} %", r[9], r[10]] for r in rows]))
    fig, axs = plt.subplots(1, 2, figsize=(11, 4.3), sharey=True)
    for ax, i, title in ((axs[0], 2, "Bajada (DL)"), (axs[1], 5, "Subida (UL)")):
        xs = [r[1] for r in rows]
        ax.plot(xs, [r[i] for r in rows], "k--", label="TBS × 1000 slots/s")
        ax.plot(xs, [r[i + 1] for r in rows], "o-", label="MAC (gNB)")
        ax.plot(xs, [r[i + 2] if r[i + 2] != "" else float("nan") for r in rows], "s-", label="TCP (iperf3)")
        ax.set_title(title); ax.set_xlabel("MCS fijo"); ax.grid(alpha=.3)
    axs[0].set_ylabel("Mbit/s"); axs[0].legend()
    fig.suptitle(f"Rendimiento vs MCS a {rows[0][0]} MHz (canal ZMQ, sin ruido)")
    fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig5_barrido_mcs.png"), dpi=130); plt.close(fig)


def section_bw_sweep(md):
    dirs = sorted((d for d in glob.glob(os.path.join(RAW, "bw*")) if "bw_mhz" in meta(d)),
                  key=lambda d: int(meta(d)["bw_mhz"]))
    if not dirs:
        return
    md.append("\n## 6. Barrido de ancho de banda (MCS adaptativo)\n")
    trows, lrows, crows, rrows, sat_rows = [], [], [], [], []
    for d in dirs:
        mt = meta(d); bw = int(mt["bw_mhz"]); nprb, coreset = BW_PROFILES[bw]
        dl = [x["mbps"] for x in (iperf(f) for f in sorted(glob.glob(os.path.join(d, "tcp_dl_*.json")))) if x]
        ul = [x["mbps"] for x in (iperf(f) for f in sorted(glob.glob(os.path.join(d, "tcp_ul_*.json")))) if x]
        rtx_ul = [x["retrans"] for x in (iperf(f) for f in sorted(glob.glob(os.path.join(d, "tcp_ul_*.json")))) if x]
        g = []
        for f in sorted(glob.glob(os.path.join(d, "tcp_dl_*.gnb.txt"))):
            g += busy(gnb_rows(f), "dl_brate")
        gu = []
        for f in sorted(glob.glob(os.path.join(d, "tcp_ul_*.gnb.txt"))):
            gu += busy(gnb_rows(f), "ul_brate")
        udl, uul = iperf(os.path.join(d, "udp_dl.json")), iperf(os.path.join(d, "udp_ul.json"))
        sd = lambda v: st.stdev(v) if len(v) > 1 else 0.0  # noqa: E731
        trows.append([bw, round(peak_38306(nprb), 1), round(tbs_bits(min(nprb, coreset), 28) * 1000 / 1e6, 1),
                      round(st.mean(r["dl_brate"] for r in g) / 1e6, 1) if g else "",
                      round(st.mean(dl), 1) if dl else "", round(sd(dl), 2),
                      round(tbs_bits(nprb - 6, 28, SYMB_PUSCH) * 1000 / 1e6, 1),
                      round(st.mean(r["ul_brate"] for r in gu) / 1e6, 1) if gu else "",
                      round(st.mean(ul), 1) if ul else "", round(sd(ul), 2), len(dl),
                      round(st.mean(r["cqi"] for r in g), 1) if g else "",
                      round(st.mean(r["dl_mcs"] for r in g), 1) if g else "",
                      round(st.mean(r["ul_mcs"] for r in gu), 1) if gu else "",
                      round(st.mean(r["pusch_snr"] for r in gu), 1) if gu else "",
                      sum(rtx_ul),
                      round(st.mean(r["dl_ok"] + r["dl_nok"] for r in g)) if g else "",
                      round(100 * sum(r["dl_nok"] for r in g) / max(1, sum(r["dl_ok"] + r["dl_nok"] for r in g)), 2) if g else "",
                      round(100 * sum(r["ul_nok"] for r in gu) / max(1, sum(r["ul_ok"] + r["ul_nok"] for r in gu)), 2) if gu else ""])
        for name, f in (("UE→DN reposo", "ping_ue_dn.txt"), ("DN→UE reposo", "ping_dn_ue.txt"),
                        ("UE→DN con carga DL", "ping_ue_dn_loaded.txt"), ("DN→UPF (solo cable)", "ping_dn_upf.txt")):
            v = ping(os.path.join(d, f))
            if v:
                q = sorted(v)
                lrows.append([bw, name, len(v), ms(min(v)), ms(st.mean(v)), ms(q[len(q) // 2]),
                              ms(q[int(.95 * (len(q) - 1))]), ms(max(v)), ms(sd(v))])
        sdl, sul = iperf(os.path.join(d, "udp_dl_sat.json")), iperf(os.path.join(d, "udp_ul_sat.json"))
        # Saturated UDP: iperf3's loss-based rate over-reports (packets queued in the gNB/UE buffers are
        # delivered after the 10 s window), so the radio capacity is taken from the gNB MAC bit rate.
        gs_dl = busy(gnb_rows(os.path.join(d, "udp_dl_sat.gnb.txt")), "dl_brate")
        gs_ul = busy(gnb_rows(os.path.join(d, "udp_ul_sat.gnb.txt")), "ul_brate")
        sat_rows.append([bw, round(st.mean(r["dl_brate"] for r in gs_dl) / 1e6, 1) if gs_dl else "",
                         round(st.mean(r["ul_brate"] for r in gs_ul) / 1e6, 1) if gs_ul else ""])
        for u, tag in ((udl, "DL"), (uul, "UL")):
            if u:
                rrows.append([bw, tag, round(u["sent_mbps"], 2), round(u["mbps"], 2), round(u["jitter_ms"], 3),
                              round(u["lost_pct"], 3)])
        for label, f in (("reposo", "stats_idle.csv"), ("TCP DL", "stats_tcp_dl.csv"), ("UDP UL", "stats_udp_ul.csv"),
                         ("UDP DL saturado", "stats_udp_dl_sat.csv")):
            for c, (cpu, mem) in sorted(stats_csv(os.path.join(d, f)).items()):
                crows.append([bw, label, c, round(cpu, 1), round(mem, 0)])

    write_csv("barrido_bw_throughput.csv", ["bw_mhz", "ts38306_dl", "tbs_dl_mcs28", "mac_dl", "tcp_dl_media",
                                            "tcp_dl_desv", "tbs_ul_mcs28", "mac_ul", "tcp_ul_media", "tcp_ul_desv",
                                            "repeticiones", "cqi", "dl_mcs", "ul_mcs", "pusch_snr_db",
                                            "tcp_ul_retransmisiones", "pdsch_por_s", "dl_nok_pct", "ul_nok_pct"], trows)
    write_csv("latencia.csv", ["bw_mhz", "prueba", "n", "min", "media", "mediana", "p95", "max", "desv"], lrows)
    write_csv("udp.csv", ["bw_mhz", "dir", "ofrecido_mbps", "recibido_mbps", "jitter_ms", "perdida_pct"], rrows)
    write_csv("cpu_mem.csv", ["bw_mhz", "fase", "contenedor", "cpu_pct", "mem_mib"], crows)

    md.append("Throughput (Mbit/s). TCP = media ± desviación de las repeticiones de 10 s.\n\n")
    md.append(md_table(["BW", "38.306 DL", "TBS DL", "MAC DL", "TCP DL", "TBS UL", "MAC UL", "TCP UL", "CQI",
                        "MCS DL/UL", "SNR PUSCH", "PDSCH/s", "NOK DL/UL"],
                       [[f"{r[0]} MHz", r[1], r[2], r[3], f"{r[4]} ± {r[5]}", r[6], r[7], f"{r[8]} ± {r[9]}",
                         r[11], f"{r[12]}/{r[13]}", f"{r[14]} dB", r[16], f"{r[17]}/{r[18]} %"] for r in trows]))
    md.append("\nLatencia (RTT, ms):\n\n")
    md.append(md_table(["BW", "Prueba", "n", "mín", "media", "mediana", "p95", "máx", "desv"], lrows))
    md.append("\nUDP saturado (" + meta(dirs[0]).get("udp_sat", "?") + " ofrecidos), tasa MAC medida por el gNB = capacidad sin TCP: "
              + ", ".join(f"{r[0]} MHz DL {r[1]} / UL {r[2]} Mbit/s" for r in sat_rows) + ".\n")
    md.append("\nUDP a tasa fija:\n\n")
    md.append(md_table(["BW", "Dir", "Ofrecido", "Recibido", "Jitter (ms)", "Pérdida %"], rrows))
    md.append("\nCPU (% de un núcleo) y memoria (MiB):\n\n")
    md.append(md_table(["BW", "Fase", "Contenedor", "CPU %", "Mem MiB"], crows))

    fig, ax = plt.subplots(figsize=(9, 4.5))
    labels = [f"{r[0]} MHz" for r in trows]
    x = range(len(trows)); w = 0.15
    series = [("TS 38.306 DL", 1), ("TBS DL MCS28", 2), ("MAC DL", 3), ("TCP DL", 4), ("TCP UL", 8)]
    for k, (name, i) in enumerate(series):
        ax.bar([xi + (k - 2) * w for xi in x], [r[i] if r[i] != "" else 0 for r in trows], w, label=name)
    ax.errorbar([xi + 1 * w for xi in x], [r[4] or 0 for r in trows], yerr=[r[5] for r in trows], fmt="none", c="k")
    ax.errorbar([xi + 2 * w for xi in x], [r[8] or 0 for r in trows], yerr=[r[9] for r in trows], fmt="none", c="k")
    ax.set_xticks(list(x)); ax.set_xticklabels(labels); ax.set_ylabel("Mbit/s"); ax.grid(axis="y", alpha=.3)
    ax.set_title("Teórico vs medido por ancho de banda"); ax.legend(fontsize=8)
    fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig6_barrido_bw.png"), dpi=130); plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 4.5))
    data, names = [], []
    for d in dirs:
        bw = meta(d)["bw_mhz"]
        for name, f in (("UE→DN", "ping_ue_dn.txt"), ("DN→UE", "ping_dn_ue.txt"), ("UE→DN carga", "ping_ue_dn_loaded.txt")):
            v = ping(os.path.join(d, f))
            if v:
                data.append(v); names.append(f"{bw} MHz\n{name}")
    ax.boxplot(data, labels=names, showfliers=True)
    ax.set_ylabel("RTT (ms)"); ax.set_title("Latencia ida y vuelta por la red 5G simulada"); ax.grid(axis="y", alpha=.3)
    plt.setp(ax.get_xticklabels(), fontsize=7)
    fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig7_latencia.png"), dpi=130); plt.close(fig)


def main():
    os.makedirs(OUT, exist_ok=True)
    md = ["# Resultados generados por scripts/analysis/throughput.py\n",
          "No editar a mano: se regenera con `python3 scripts/analysis/throughput.py`.\n"]
    section_tables(md)
    section_tbs(md)
    section_tbs_validation(md)
    section_bler(md)
    section_mcs_sweep(md)
    section_bw_sweep(md)
    with open(os.path.join(OUT, "resumen.md"), "w") as f:
        f.write("".join(x if x.endswith("\n") else x + "\n" for x in md))
    print(f"wrote {OUT}/resumen.md and {len(glob.glob(os.path.join(OUT, '*.png')))} figures")


if __name__ == "__main__":
    main()
