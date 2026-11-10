# Evidencias: core en la Raspberry Pi, gNB con USRP B200 en el PC, celular comercial (2026-11-10)

Montaje: core Open5GS 2.7.7 en la Raspberry Pi 5 (`10.42.0.28`); gNB srsRAN Project 24.10.1 con USRP B200
(USB 3) en el PC (`10.42.0.1`), unidos por un cable Ethernet (adaptador USB de 100 Mbit/s). Celda n3 FDD,
DL 1842.5 MHz / UL 1747.5 MHz, 10 MHz, SCS 15 kHz, PCI 1, PLMN 001/01, TAC 7, ganancia TX 89.75 dB.
UE: OnePlus Nord CE 2 Lite 5G (CPH2409, OxygenOS 14) con la SIM programada (IMSI `001010123456780`),
en *NR only*, a ~1 m de las antenas y con el Wi-Fi apagado. Arranque con `make picore-up`.

## Resumen

| Prueba | Resultado | Archivo |
|---|---|---|
| Celular en la celda | `NR_SA`, PCI 1, ARFCN 368410, banda 3, PLMN 001/01; SS-RSRP −73 dBm, SS-RSRQ −11 dB, SS-SINR 38 dB | `celular_estado.txt` |
| Registro y sesión PDU | `Registration request` → `Registration complete` en ~200 ms; IP `10.99.0.x` | `cable_n2_ngap_mensajes.txt` |
| N2 por el cable | NGAP/SCTP entre `10.42.0.1` y `10.42.0.28:38412` | `cable_n2_ngap.pcap` |
| N3 por el cable | GTP-U `10.42.0.1:2152` ↔ `10.42.0.28:2152` (105 MB en la captura completa) | `cable_n3_gtpu_muestra.pcap` |
| Métricas MAC DL (consola del gNB) | CQI 15, MCS 28, 27.5 Mbit/s medio (29 máx.), BLER 0.02 % | `gnb_metricas_resumen.txt`, `gnb_metricas_consola.txt` |
| Métricas MAC UL | MCS 27.4, 30.2 Mbit/s medio (34 máx.), SNR PUSCH 27.7 dB, BLER 5.6 % (0-4 % sin el desvanecimiento de 2 s) | ídem |
| HTTPS desde el celular (Cloudflare) | DL 24.0 / 25.7 / 25.6 Mbit/s; UL 24.0 / 23.3 Mbit/s; PC por Wi-Fi: 76-82 Mbit/s | `throughput_curl.txt` |
| Latencia celular → DN (100 pings) | 0 % pérdida, 12.2 / 31.1 / 45.0 ms | `ping_celular_dn.txt` |
| Latencia DN → celular (50 pings) | 0 % pérdida, 12.9 / 28.9 / 39.8 ms | `ping_dn_celular.txt` |
| Latencia celular → 8.8.8.8 (100 pings) | 0 % pérdida, 22.8 / 56.8 / 197.9 ms | `ping_celular_8888.txt` |
| Latencia UPF → 8.8.8.8 / PC ↔ Pi | 15.7 ms / 0.75 ms | `ping_upf_8888.txt`, `ping_pc_pi_cable.txt` |
| RF bajo carga (HackRF One) | SSB 100/100, PCI 1, +1.3 ppm, canal ocupado 9.31 de 10 MHz | `rf_bajo_carga.txt`, `../../rf/20261110-154742/` |
| Recursos | gNB ~0.9 núcleos y 2.2 GiB (PC); Pi 58.7 °C, carga 0.3 | `recursos_*_bajo_carga.txt` |

`gnb_bajo_carga.log` es un extracto del log del gNB a nivel `info` durante una descarga (PRACH, RRC,
PDSCH/PUSCH); a ese nivel el log no guarda todas las asignaciones, así que las estadísticas se toman de la
consola del gNB (`gnb_metricas_consola.txt`). Las capturas completas (`*_completo.pcap`, ~21 MB) no están en git.

## Capturas de pantalla del celular (`capturas/`)

| Archivo | Qué muestra |
|---|---|
| `1_red_siscom2_nr_sa.png` | *Información del teléfono*: red SISCOM2, datos conectados, tipo de red **NR_SA**, HOME, IMSI de la SIM (IMEI tapado) |
| `2_senal_y_nr_only.png` | Señal −70 dBm, NR CONNECTED, tipo de red preferido **NR only** |
| `3_apn_internet.png` | APN `SISCOM2` → `internet` |
| `4_apn_mcc_mnc_ipv4.png` | MCC 001, MNC 01, tipo `default,supl`, protocolo IPv4, sin autenticación |
| `5_test_velocidad.png` | fast.com por la red 5G: 25 Mbit/s de bajada, 41 ms en reposo y 900 ms con carga (IP pública tapada). Su subida de 47 Mbit/s no es fiable: supera el máximo MAC de la celda (34 Mbit/s) |

## Observaciones

- El celular solo se conecta en **NR only**: su perfil de operador para SIM desconocidas permite solo NSA
  (`carrier_nr_availabilities_int_array = [1]`). Ver `docs/sim-oneplus.md` §4.2.
- Tras un registro, el celular a veces se desregistra a los ~14 s y vuelve a registrarse (*SA backoff*);
  se ve en `cable_n2_ngap_mensajes.txt` como `PDUSessionResourceRelease` + `UEContextRelease` y un nuevo
  `InitialUEMessage`.
- Los re-registros reutilizan el contexto de seguridad (no hay `Authentication request`); la autenticación
  5G-AKA completa del primer registro está en la captura NGAP propia del gNB (`gnb_ngap.pcap`).
- El límite de velocidad es la radio (10 MHz, SISO, 64QAM, DCI de *fallback*), no Internet ni el cable.
- `gnb_ngap_registro_inicial.pcap` es la captura NGAP propia del gNB (desde el arranque de la celda). Usa el
  DLT de usuario 152: en Wireshark, *Preferences → Protocols → DLT_USER* → `User 5 (DLT=152)` → `ngap`
  (con tshark: `-o 'uat:user_dlts:"User 5 (DLT=152)","ngap","0","","0",""'`). Su resumen está en
  `gnb_ngap_nas_mensajes.txt`: Registration request → Authentication request/response → Security mode
  command → InitialContextSetup → PDUSessionResourceSetup en ~0.5 s, **sin Synch failure** (la SIM y el
  core aceptaron el SQN al primer intento: Ki/OPc bien programados).
