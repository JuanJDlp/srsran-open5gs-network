# Validación RF: capture.iq

Config gNB: `configs/gnb/gnb_usrp_10mhz.yml` (dl_arfcn 368500, 10 MHz, SCS 15 kHz, PCI 1). Captura a 1842.5000 MHz, 15.36 Msps.

| Resultado | Detalle |
|---|---|
| PASS | saturación: 0.000 % de muestras recortadas |
| FAIL | no se encontró ningún SSB (mejor correlación PSS 0.062, umbral 0.2). ¿El gNB transmite? ¿Frecuencia o ganancia correctas? |
| PASS | señal ocupa 1842.496-1842.504 MHz (0.01 MHz, max-hold), canal configurado 1837.500-1847.500 MHz |
| INFO | sin tráfico el gNB solo emite SSB/control; para ver los 10 MHz llenos, capturar mientras el UE descarga (iperf3 -R) |

Figuras: `espectro.png`, `espectrograma.png`
