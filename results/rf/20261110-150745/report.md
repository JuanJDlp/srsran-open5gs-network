# Validación RF: capture.iq

Config gNB: `configs/gnb/gnb_usrp_10mhz.yml` (dl_arfcn 368500, 10 MHz, SCS 15 kHz, PCI 1). Captura a 1842.5000 MHz, 15.36 Msps.

| Resultado | Detalle |
|---|---|
| PASS | saturación: 0.000 % de muestras recortadas |
| PASS | SSB detectado: 74 SSB en 74 ráfagas, SNR en la banda del SSB ~-4.1 dB |
| PASS | PCI medido 1 (N_ID1 0, N_ID2 1), configurado 1; margen SSS 1.9x |
| PASS | frecuencia del SSB 1842.0512 MHz, esperada 1842.0500 MHz (ARFCN 368410); diferencia +1.2 kHz = +0.6 ppm (error de reloj HackRF+USRP) |
| INFO | periodo de ráfaga SSB 10.0 ms (1 SSB por ráfaga) |
| PASS | señal ocupa 1842.496-1842.504 MHz (0.01 MHz, max-hold), canal configurado 1837.500-1847.500 MHz |
| INFO | sin tráfico el gNB solo emite SSB/control; para ver los 10 MHz llenos, capturar mientras el UE descarga (iperf3 -R) |

Figuras: `espectro.png`, `espectrograma.png`, `ssb_pss.png`
