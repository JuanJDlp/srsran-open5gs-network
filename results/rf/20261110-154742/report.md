# Validación RF: capture.iq

Config gNB: `configs/gnb/gnb_usrp_10mhz.yml` (dl_arfcn 368500, 10 MHz, SCS 15 kHz, PCI 1). Captura a 1842.5000 MHz, 15.36 Msps.

| Resultado | Detalle |
|---|---|
| PASS | saturación: 0.000 % de muestras recortadas |
| PASS | SSB detectado: 100 SSB en 100 ráfagas, SNR en la banda del SSB ~12.3 dB |
| PASS | PCI medido 1 (N_ID1 0, N_ID2 1), configurado 1; margen SSS 7.0x |
| PASS | frecuencia del SSB 1842.0524 MHz, esperada 1842.0500 MHz (ARFCN 368410); diferencia +2.4 kHz = +1.3 ppm (error de reloj HackRF+USRP) |
| INFO | periodo de ráfaga SSB 10.0 ms (1 SSB por ráfaga) |
| PASS | señal ocupa 1837.816-1847.128 MHz (9.31 MHz, max-hold), canal configurado 1837.500-1847.500 MHz |
| INFO | sin tráfico el gNB solo emite SSB/control; para ver los 10 MHz llenos, capturar mientras el UE descarga (iperf3 -R) |

Figuras: `espectro.png`, `espectrograma.png`, `ssb_pss.png`
