# Resultados generados por scripts/analysis/throughput.py
No editar a mano: se regenera con `python3 scripts/analysis/throughput.py`.
## 1. Tablas MCS/CQI y eficiencia espectral
Tabla MCS 1 (TS 38.214 5.1.3.1-1). SE = Qm·R; SNR mínima de Shannon = 2^SE − 1.

| MCS | Mod | Qm | R×1024 | SE (bit/RE) | SNR Shannon (dB) |
|---|---|---|---|---|---|
| 0 | QPSK | 2 | 120 | 0.2344 | -7.54 |
| 1 | QPSK | 2 | 157 | 0.3066 | -6.26 |
| 2 | QPSK | 2 | 193 | 0.377 | -5.25 |
| 3 | QPSK | 2 | 251 | 0.4902 | -3.93 |
| 4 | QPSK | 2 | 308 | 0.6016 | -2.86 |
| 5 | QPSK | 2 | 379 | 0.7402 | -1.74 |
| 6 | QPSK | 2 | 449 | 0.877 | -0.78 |
| 7 | QPSK | 2 | 526 | 1.0273 | 0.16 |
| 8 | QPSK | 2 | 602 | 1.1758 | 1.0 |
| 9 | QPSK | 2 | 679 | 1.3262 | 1.78 |
| 10 | 16QAM | 4 | 340 | 1.3281 | 1.79 |
| 11 | 16QAM | 4 | 378 | 1.4766 | 2.51 |
| 12 | 16QAM | 4 | 434 | 1.6953 | 3.5 |
| 13 | 16QAM | 4 | 490 | 1.9141 | 4.42 |
| 14 | 16QAM | 4 | 553 | 2.1602 | 5.4 |
| 15 | 16QAM | 4 | 616 | 2.4062 | 6.34 |
| 16 | 16QAM | 4 | 658 | 2.5703 | 6.94 |
| 17 | 64QAM | 6 | 438 | 2.5664 | 6.92 |
| 18 | 64QAM | 6 | 466 | 2.7305 | 7.51 |
| 19 | 64QAM | 6 | 517 | 3.0293 | 8.55 |
| 20 | 64QAM | 6 | 567 | 3.3223 | 9.54 |
| 21 | 64QAM | 6 | 616 | 3.6094 | 10.49 |
| 22 | 64QAM | 6 | 666 | 3.9023 | 11.45 |
| 23 | 64QAM | 6 | 719 | 4.2129 | 12.44 |
| 24 | 64QAM | 6 | 772 | 4.5234 | 13.42 |
| 25 | 64QAM | 6 | 822 | 4.8164 | 14.34 |
| 26 | 64QAM | 6 | 873 | 5.1152 | 15.27 |
| 27 | 64QAM | 6 | 910 | 5.332 | 15.94 |
| 28 | 64QAM | 6 | 948 | 5.5547 | 16.63 |

## 2. TBS, LDPC y velocidad teórica para nuestra celda
Supuestos (verificados con el log del scheduler, sección 3): PDSCH en símbolos 1–13 (13), PUSCH 0–13 (14), DMRS tipo A pos2 + 2 adicionales = 3 símbolos × 12 RE, sin xOverhead, 1 capa. PRB de DL limitados por CORESET#0 (DCI 1_0 en espacio común).

Velocidad máxima: fórmula TS 38.306 §4.1.2 (v=1, Qm=6, f=1, Rmax=948/1024, μ=0, OH 14 % DL / 8 % UL) vs TBS real a MCS 28 × 1000 slots/s:

| BW | N_PRB | 38.306 DL | 38.306 UL | PRB DL | TBS DL MCS28 | PRB UL | TBS UL MCS28 |
|---|---|---|---|---|---|---|---|
| 10 MHz | 52 | 41.7 Mb/s | 44.6 Mb/s | 48 | 31.8 Mb/s | 46 | 33.8 Mb/s |
| 15 MHz | 79 | 63.4 Mb/s | 67.8 Mb/s | 48 | 31.8 Mb/s | 73 | 53.3 Mb/s |
| 20 MHz | 106 | 85.1 Mb/s | 91.0 Mb/s | 96 | 63.5 Mb/s | 100 | 73.8 Mb/s |

LDPC para algunos MCS con 48 PRB (DL 10 MHz). G = N_RE·Qm bits codificados:

| MCS | Mod | R | TBS A | BG | C | K' | Zc | K | relleno | N | E/CB | tasa/CB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | QPSK | 0.117 | 1352 | BG2 | 1 | 1368 | 144 | 1440 | 72 | 7200 | 11520 | 0.119 |
| 3 | QPSK | 0.245 | 2856 | BG2 | 1 | 2872 | 288 | 2880 | 8 | 14400 | 11520 | 0.249 |
| 9 | QPSK | 0.663 | 7552 | BG1 | 1 | 7576 | 352 | 7744 | 168 | 23232 | 11520 | 0.658 |
| 10 | 16QAM | 0.332 | 7680 | BG1 | 1 | 7704 | 352 | 7744 | 40 | 23232 | 23040 | 0.334 |
| 17 | 64QAM | 0.428 | 14856 | BG1 | 2 | 7464 | 352 | 7744 | 280 | 23232 | 17280 | 0.432 |
| 28 | 64QAM | 0.926 | 31752 | BG1 | 4 | 7968 | 384 | 8448 | 480 | 25344 | 8640 | 0.922 |
| 27 (1 PRB) | 64QAM | 0.889 | 640 | BG1 | 1 | 656 | 30 | 660 | 4 | 1980 | 720 | 0.911 |
| 3 (42 PRB) | QPSK | 0.245 | 2472 | BG2 | 1 | 2488 | 256 | 2560 | 72 | 12800 | 10080 | 0.247 |

Polar (control): K = carga + CRC 24, E = bits tras rate matching (PDCCH: 108·AL).

| Caso | K | E | N | K/E | Rate matching |
|---|---|---|---|---|---|
| PBCH (MIB 32 b) | 56 | 864 | 512 | 0.065 | repetición |
| DCI 1_0 AL1 | 63 | 108 | 128 | 0.583 | shortening |
| DCI 1_0 AL2 | 63 | 216 | 256 | 0.292 | puncturing |
| DCI 1_0 AL4 | 63 | 432 | 512 | 0.146 | puncturing |
| DCI 1_0 AL8 | 63 | 864 | 512 | 0.073 | repetición |

## 3. Validación: TBS calculado vs TBS que usa el scheduler del gNB
213/213 asignaciones distintas (≥ 12 símbolos) coinciden byte a byte con TS 38.214 §5.1.3.2 usando el MCS del log (PDSCH) o el fijado (PUSCH). Las otras 20, todas PUSCH de 1-5 PRB, solo se explican con un MCS menor (27): el scheduler baja el MCS mientras la tasa efectiva supere 0.95 (el log de PUSCH no imprime el MCS, así que estas se infieren, no se validan). Las más frecuentes:

| BW | Canal | MCS fijado | MCS usado | PRB | Símb. | Veces | TBS log (B) | TBS calc (B) | ¿= |
|---|---|---|---|---|---|---|---|---|---|
| 10 | PUSCH | 3 | 3 | 46 | 14 | 4691 | 372 | 372 | sí |
| 10 | PUSCH | 9 | 9 | 46 | 14 | 4477 | 1008 | 1008 | sí |
| 10 | PUSCH | 28 | 28 | 46 | 14 | 3935 | 4227 | 4227 | sí |
| 10 | PDSCH | 3 | 3 | 48 | 13 | 3866 | 357 | 357 | sí |
| 10 | PDSCH | 9 | 9 | 48 | 13 | 3719 | 944 | 944 | sí |
| 10 | PDSCH | 28 | 28 | 48 | 13 | 3384 | 3969 | 3969 | sí |
| 15 | PDSCH | 28 | 28 | 48 | 13 | 3356 | 3969 | 3969 | sí |
| 15 | PUSCH | 28 | 28 | 73 | 14 | 3347 | 6661 | 6661 | sí |
| 20 | PDSCH | 28 | 28 | 96 | 13 | 2604 | 7941 | 7941 | sí |
| 20 | PUSCH | 28 | 28 | 100 | 14 | 2581 | 9222 | 9222 | sí |
| 10 | PDSCH | 28 | 28 | 2 | 13 | 2140 | 169 | 169 | sí |
| 20 | PDSCH | 28 | 28 | 3 | 13 | 1783 | 253 | 253 | sí |
| 15 | PDSCH | 28 | 28 | 2 | 13 | 1638 | 169 | 169 | sí |
| 10 | PDSCH | 9 | 9 | 3 | 13 | 1342 | 60 | 60 | sí |

## 4. Canal: BLER vs SNR (AWGN, PHY de srsRAN 4G) y elección de MCS
Simulación a nivel de enlace con `pusch_nr_bler_test` (48 PRB × 14 símbolos, LDPC + QAM + DMRS, estimación de canal perfecta). SNR = Es/N0 por RE. Umbral de trabajo: BLER 10 % (objetivo típico de la 1.ª transmisión con HARQ).

| MCS | Mod | SE | SNR Shannon | SNR @BLER 10 % | SNR @BLER 1 % | Brecha |
|---|---|---|---|---|---|---|
| 0 | QPSK | 0.234 | -7.54 dB | -5.48 dB | -5.32 dB | 2.05 dB |
| 1 | QPSK | 0.307 | -6.26 dB | -4.35 dB | -4.14 dB | 1.91 dB |
| 2 | QPSK | 0.377 | -5.25 dB | -3.45 dB | -3.3 dB | 1.8 dB |
| 3 | QPSK | 0.49 | -3.93 dB | -2.34 dB | -2.15 dB | 1.59 dB |
| 4 | QPSK | 0.602 | -2.86 dB | -1.34 dB | -1.17 dB | 1.52 dB |
| 5 | QPSK | 0.74 | -1.74 dB | -0.36 dB | -0.2 dB | 1.38 dB |
| 6 | QPSK | 0.877 | -0.78 dB | 0.6 dB | 0.73 dB | 1.37 dB |
| 7 | QPSK | 1.027 | 0.16 dB | 1.74 dB | 1.98 dB | 1.58 dB |
| 8 | QPSK | 1.176 | 1.0 dB | 2.6 dB | 2.74 dB | 1.6 dB |
| 9 | QPSK | 1.326 | 1.78 dB | 3.68 dB | 3.87 dB | 1.9 dB |
| 10 | 16QAM | 1.328 | 1.79 dB | 5.21 dB | 5.46 dB | 3.42 dB |
| 11 | 16QAM | 1.477 | 2.51 dB | 5.62 dB | 5.83 dB | 3.11 dB |
| 12 | 16QAM | 1.695 | 3.5 dB | 6.38 dB | 6.63 dB | 2.88 dB |
| 13 | 16QAM | 1.914 | 4.42 dB | 7.12 dB | 7.25 dB | 2.7 dB |
| 14 | 16QAM | 2.16 | 5.4 dB | 8.05 dB | 8.24 dB | 2.64 dB |
| 15 | 16QAM | 2.406 | 6.34 dB | 8.62 dB | 8.75 dB | 2.29 dB |
| 16 | 16QAM | 2.57 | 6.94 dB | 9.55 dB | 9.7 dB | 2.61 dB |
| 17 | 64QAM | 2.566 | 6.92 dB | 10.11 dB | 10.3 dB | 3.19 dB |
| 18 | 64QAM | 2.73 | 7.51 dB | 10.72 dB | 10.94 dB | 3.21 dB |
| 19 | 64QAM | 3.029 | 8.55 dB | 11.6 dB | 11.73 dB | 3.05 dB |
| 20 | 64QAM | 3.322 | 9.54 dB | 12.22 dB | 12.44 dB | 2.68 dB |
| 21 | 64QAM | 3.609 | 10.49 dB | 13.12 dB | 13.25 dB | 2.63 dB |
| 22 | 64QAM | 3.902 | 11.45 dB | 14.08 dB | 14.22 dB | 2.63 dB |
| 23 | 64QAM | 4.213 | 12.44 dB | 15.21 dB | 15.43 dB | 2.77 dB |
| 24 | 64QAM | 4.523 | 13.42 dB | 16.78 dB | 17.04 dB | 3.35 dB |
| 25 | 64QAM | 4.816 | 14.34 dB | 17.12 dB | 17.25 dB | 2.78 dB |
| 26 | 64QAM | 5.115 | 15.27 dB | 19.09 dB | 19.23 dB | 3.82 dB |
| 27 | 64QAM | 5.332 | 15.94 dB | 20.73 dB | 20.96 dB | 4.79 dB |
| 28 | 64QAM | 5.555 | 16.63 dB | 21.15 dB | 21.33 dB | 4.52 dB |

CQI (tabla 1) → MCS con el mismo (Qm, R) → SNR necesaria para BLER 10 %:

| CQI | Mod | R×1024 | MCS equiv. | SNR @10 % |
|---|---|---|---|---|
| 1 | QPSK | 78 | — | — |
| 2 | QPSK | 120 | 0 | -5.5 |
| 3 | QPSK | 193 | 2 | -3.4 |
| 4 | QPSK | 308 | 4 | -1.3 |
| 5 | QPSK | 449 | 6 | 0.6 |
| 6 | QPSK | 602 | 8 | 2.6 |
| 7 | 16QAM | 378 | 11 | 5.6 |
| 8 | 16QAM | 490 | 13 | 7.1 |
| 9 | 16QAM | 616 | 15 | 8.6 |
| 10 | 64QAM | 466 | 18 | 10.7 |
| 11 | 64QAM | 567 | 20 | 12.2 |
| 12 | 64QAM | 666 | 22 | 14.1 |
| 13 | 64QAM | 772 | 24 | 16.8 |
| 14 | 64QAM | 873 | 26 | 19.1 |
| 15 | 64QAM | 948 | 28 | 21.2 |

Polar: SNR para WER 1 %: pbch -6.17 dB, dci_al2 0.72 dB, dci_al4 -2.7 dB, dci_al8 -5.72 dB.

## 5. Barrido de MCS fijo (red ZMQ real)
Teórico = TBS × 1000 slots/s; MAC = brate del gNB (segundos con carga); TCP = iperf3.

| BW | MCS | DL teórico | DL MAC | DL TCP | UL teórico | UL MAC | UL TCP | NOK DL | PDSCH/s | PUSCH/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 10 | 0 | 1.35 | 1.2 | 1.12 | 1.42 | 1.4 | 1.06 | 0.0 % | 988 | 994 |
| 10 | 4 | 3.5 | 3.08 | 2.87 | 3.75 | 3.62 | 3.15 | 0.0 % | 986 | 972 |
| 10 | 9 | 7.55 | 6.83 | 6.31 | 8.06 | 8.0 | 7.24 | 0.0 % | 984 | 994 |
| 10 | 14 | 12.55 | 11.0 | 10.4 | 13.06 | 13.0 | 11.71 | 0.0 % | 991 | 994 |
| 10 | 19 | 17.42 | 15.82 | 14.38 | 18.43 | 18.0 | 16.45 | 0.0 % | 986 | 994 |
| 10 | 24 | 26.12 | 24.0 | 20.91 | 27.66 | 27.0 | 24.96 | 0.0 % | 994 | 994 |
| 10 | 28 | 31.75 | 28.6 | 26.54 | 33.82 | 34.0 | 30.32 | 0.0 % | 982 | 994 |

## 6. Barrido de ancho de banda (MCS adaptativo)
Throughput (Mbit/s). TCP = media ± desviación de las repeticiones de 10 s.

| BW | 38.306 DL | TBS DL | MAC DL | TCP DL | TBS UL | MAC UL | TCP UL | CQI | MCS DL/UL | SNR PUSCH | PDSCH/s | NOK DL/UL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 10 MHz | 41.7 | 31.8 | 28.1 | 26.4 ± 0.06 | 33.8 | 33.2 | 30.1 ± 0.26 | 15.0 | 28/28 | 65.5 dB | 965 | 0.0/0.0 % |
| 15 MHz | 63.4 | 31.8 | 29.1 | 26.7 ± 0.16 | 53.3 | 52.2 | 43.4 ± 1.1 | 15.0 | 28/28 | 65.5 dB | 970 | 0.0/0.0 % |
| 20 MHz | 85.1 | 63.5 | 58.3 | 45.1 ± 0.38 | 73.8 | 72.4 | 46.5 ± 1.61 | 15.0 | 28/28 | 65.2 dB | 990 | 0.0/0.0 % |

Latencia (RTT, ms):

| BW | Prueba | n | mín | media | mediana | p95 | máx | desv |
|---|---|---|---|---|---|---|---|---|
| 10 | UE→DN reposo | 100 | 18.9 | 29.0 | 29.2 | 38.4 | 40.1 | 6.1 |
| 10 | DN→UE reposo | 50 | 19.7 | 30.5 | 30.2 | 39.5 | 39.9 | 6.3 |
| 10 | UE→DN con carga DL | 32 | 18.3 | 179.3 | 181.0 | 317.0 | 332.0 | 94.1 |
| 10 | DN→UPF (solo cable) | 50 | 0.0 | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 |
| 15 | UE→DN reposo | 100 | 18.9 | 29.9 | 30.6 | 38.9 | 39.2 | 6.0 |
| 15 | DN→UE reposo | 50 | 19.9 | 30.0 | 30.7 | 39.8 | 40.5 | 6.2 |
| 15 | UE→DN con carga DL | 32 | 19.0 | 179.6 | 182.0 | 322.0 | 333.0 | 94.4 |
| 15 | DN→UPF (solo cable) | 50 | 0.0 | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 |
| 20 | UE→DN reposo | 100 | 18.9 | 29.2 | 29.9 | 38.1 | 40.0 | 6.0 |
| 20 | DN→UE reposo | 50 | 20.7 | 30.7 | 30.5 | 39.9 | 40.6 | 6.2 |
| 20 | UE→DN con carga DL | 32 | 22.6 | 182.9 | 181.0 | 317.0 | 340.0 | 96.6 |
| 20 | DN→UPF (solo cable) | 50 | 0.0 | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 |

UDP saturado (80M ofrecidos), tasa MAC medida por el gNB = capacidad sin TCP: 10 MHz DL 28.8 / UL 32.8 Mbit/s, 15 MHz DL 30.0 / UL 53.0 Mbit/s, 20 MHz DL 59.0 / UL 70.6 Mbit/s.

UDP a tasa fija:

| BW | Dir | Ofrecido | Recibido | Jitter (ms) | Pérdida % |
|---|---|---|---|---|---|
| 10 | DL | 10.0 | 10.0 | 0.616 | 0 |
| 10 | UL | 10.0 | 10.0 | 1.428 | 0 |
| 15 | DL | 10.0 | 10.0 | 0.605 | 0 |
| 15 | UL | 10.0 | 10.0 | 2.061 | 0 |
| 20 | DL | 10.0 | 10.0 | 0.534 | 0 |
| 20 | UL | 10.0 | 10.0 | 2.25 | 0 |

CPU (% de un núcleo) y memoria (MiB):

| BW | Fase | Contenedor | CPU % | Mem MiB |
|---|---|---|---|---|
| 10 | reposo | amf | 0.0 | 395.0 |
| 10 | reposo | gnb | 170.5 | 2342.0 |
| 10 | reposo | mongo | 41.7 | 132.0 |
| 10 | reposo | smf | 0.0 | 35.0 |
| 10 | reposo | ue | 47.6 | 331.0 |
| 10 | reposo | upf | 0.0 | 20.0 |
| 10 | TCP DL | amf | 0.0 | 395.0 |
| 10 | TCP DL | gnb | 218.6 | 2311.0 |
| 10 | TCP DL | mongo | 35.4 | 77.0 |
| 10 | TCP DL | smf | 0.0 | 35.0 |
| 10 | TCP DL | ue | 134.2 | 298.0 |
| 10 | TCP DL | upf | 11.5 | 20.0 |
| 10 | UDP UL | amf | 0.0 | 395.0 |
| 10 | UDP UL | gnb | 192.4 | 2338.0 |
| 10 | UDP UL | mongo | 17.1 | 77.0 |
| 10 | UDP UL | smf | 0.0 | 35.0 |
| 10 | UDP UL | ue | 72.5 | 324.0 |
| 10 | UDP UL | upf | 2.6 | 20.0 |
| 10 | UDP DL saturado | amf | 0.0 | 395.0 |
| 10 | UDP DL saturado | gnb | 220.6 | 2340.0 |
| 10 | UDP DL saturado | mongo | 22.0 | 134.0 |
| 10 | UDP DL saturado | smf | 0.0 | 35.0 |
| 10 | UDP DL saturado | ue | 141.9 | 329.0 |
| 10 | UDP DL saturado | upf | 15.2 | 20.0 |
| 15 | reposo | amf | 0.0 | 407.0 |
| 15 | reposo | gnb | 172.2 | 2358.0 |
| 15 | reposo | mongo | 28.4 | 77.0 |
| 15 | reposo | smf | 0.0 | 35.0 |
| 15 | reposo | ue | 48.2 | 343.0 |
| 15 | reposo | upf | 0.0 | 20.0 |
| 15 | TCP DL | amf | 0.0 | 407.0 |
| 15 | TCP DL | gnb | 222.8 | 2325.0 |
| 15 | TCP DL | mongo | 27.3 | 103.0 |
| 15 | TCP DL | smf | 0.0 | 35.0 |
| 15 | TCP DL | ue | 144.1 | 307.0 |
| 15 | TCP DL | upf | 13.0 | 20.0 |
| 15 | UDP UL | amf | 0.0 | 407.0 |
| 15 | UDP UL | gnb | 197.6 | 2355.0 |
| 15 | UDP UL | mongo | 25.2 | 122.0 |
| 15 | UDP UL | smf | 0.0 | 35.0 |
| 15 | UDP UL | ue | 78.7 | 338.0 |
| 15 | UDP UL | upf | 2.7 | 20.0 |
| 15 | UDP DL saturado | amf | 0.0 | 407.0 |
| 15 | UDP DL saturado | gnb | 231.3 | 2356.0 |
| 15 | UDP DL saturado | mongo | 30.2 | 100.0 |
| 15 | UDP DL saturado | smf | 0.0 | 35.0 |
| 15 | UDP DL saturado | ue | 158.7 | 342.0 |
| 15 | UDP DL saturado | upf | 16.6 | 20.0 |
| 20 | reposo | amf | 0.0 | 420.0 |
| 20 | reposo | gnb | 181.2 | 2378.0 |
| 20 | reposo | mongo | 0.9 | 77.0 |
| 20 | reposo | smf | 0.0 | 35.0 |
| 20 | reposo | ue | 63.2 | 363.0 |
| 20 | reposo | upf | 0.0 | 19.0 |
| 20 | TCP DL | amf | 0.0 | 420.0 |
| 20 | TCP DL | gnb | 244.9 | 2343.0 |
| 20 | TCP DL | mongo | 31.4 | 77.0 |
| 20 | TCP DL | smf | 0.0 | 35.0 |
| 20 | TCP DL | ue | 226.6 | 325.0 |
| 20 | TCP DL | upf | 17.4 | 20.0 |
| 20 | UDP UL | amf | 0.0 | 420.0 |
| 20 | UDP UL | gnb | 196.0 | 2373.0 |
| 20 | UDP UL | mongo | 20.8 | 99.0 |
| 20 | UDP UL | smf | 0.0 | 35.0 |
| 20 | UDP UL | ue | 83.3 | 359.0 |
| 20 | UDP UL | upf | 2.2 | 19.0 |
| 20 | UDP DL saturado | amf | 0.0 | 420.0 |
| 20 | UDP DL saturado | gnb | 252.7 | 2375.0 |
| 20 | UDP DL saturado | mongo | 30.8 | 140.0 |
| 20 | UDP DL saturado | smf | 0.0 | 35.0 |
| 20 | UDP DL saturado | ue | 233.8 | 362.0 |
| 20 | UDP DL saturado | upf | 19.4 | 19.0 |
