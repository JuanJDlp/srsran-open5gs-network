# 5GDockerNetwork — Red 5G SA simulada en Docker (SISCOM2, Fase 1)

Red 5G Standalone completa en un solo PC y **toda en contenedores**:

- **Core 5G: Open5GS 2.7.7**, con una función de red (NF) por contenedor (enfoque NFV/CNF).
- **gNB: srsRAN Project `release_24_10_1`**, monolítico (CU+DU).
- **UE: srsUE** (srsRAN 4G `release_25_10`), con USIM por software.
- **Radio simulada con ZeroMQ**: gNB y UE intercambian muestras IQ por TCP. Toda la pila NR se ejecuta
  de verdad: PHY con LDPC/Polar, MAC, RLC, PDCP, RRC y NAS.

También puede repartirse en dos equipos: core y gNB en una Raspberry Pi 5 y el UE en el PC
(ver [Modo distribuido](#modo-distribuido-core-y-gnb-en-una-raspberry-pi-5-ue-en-el-pc)).

No se instala nada en el host aparte de Docker, ni se tocan sus rutas, `iptables` ni `sysctl`.

Todos los archivos de configuración (`configs/`, `docker-compose.yml`, `.env`) llevan un comentario
en español al lado de cada entrada que explica qué significa su valor.

## Arquitectura

```
          air 10.88.3.0/24            ran 10.88.2.0/24                cn 10.88.1.0/24
 ┌────────────┐  Uu (ZMQ IQ)  ┌───────────────┐  N2 NGAP/SCTP :38412  ┌──────────────────────────┐
 │ ue  .21    │◄────────────►│ gnb  air .20  │──────────────────────►│ amf  cn .2 / ran .2       │
 │ srsUE      │ tcp 2000/2001 │      ran .20  │  N3 GTP-U/UDP :2152   │ upf  cn .3 / ran .3 / dn .3│
 │ tun_srsue  │               │ srsRAN 24.10.1│◄─────────────────────►│ smf .11 nrf .10 ausf .12  │
 │ 10.99.0.x  │               └───────────────┘                        │ udm .13 udr .14 pcf .15   │
 └────────────┘                                                         │ bsf .16 nssf .17          │
                                                                        │ mongo .5 webui .6         │
          dn 10.88.4.0/24                                               └──────────────────────────┘
 ┌──────────────┐  N6 (IP)  UPF ── ogstun 10.99.0.1 (gateway del pool de UEs 10.99.0.0/16)
 │ dn .10 iperf3│◄──────────  SBI (HTTP/2 :7777) y N4 (PFCP :8805) van por la red cn
 └──────────────┘
```

Cada grupo de interfaces 3GPP tiene su propia red Docker, con un nombre de bridge fijo. Así, capturar
en un bridge equivale a capturar una interfaz concreta.

| Bridge del host | Red | Interfaces |
|---|---|---|
| `br-5g-cn` | `10.88.1.0/24` | SBI (HTTP/2), N4 (PFCP) |
| `br-5g-ran` | `10.88.2.0/24` | N2 (NGAP/SCTP), N3 (GTP-U); N1 (NAS) viaja dentro de NGAP |
| `br-5g-air` | `10.88.3.0/24` | Uu simulada (ZMQ) |
| `br-5g-dn` | `10.88.4.0/24` | N6 |

## Requisitos

- Linux con Docker Engine y Compose v2. Probado solo en Ubuntu 24.04, Docker 27.2.1 y Compose 2.29.2.
  No sirve Docker Desktop: no tiene SCTP ni TUN.
- Módulo SCTP del kernel. Si `lsmod | grep sctp` no muestra nada, ejecutar `sudo modprobe sctp`.
- `/dev/net/tun`, unos 4 GB de RAM libres y unos 4 GB de disco (imágenes ~1.8 GB + caché de compilación ~1.7 GB).
- Al menos 12 hilos de CPU para el reparto por defecto, que se cambia en `.env`
  (`CORE_CPUS`, `GNB_CPUS`, `UE_CPUS`).

## Uso

```bash
make build     # compila las imágenes del gNB y de srsUE (~15 min la primera vez) y descarga las de Open5GS
make up        # core -> gNB (NG Setup) -> UE (registro + sesión PDU); tarda ~30 s
make verify    # 29 comprobaciones de extremo a extremo (V0-V5); termina con código ≠ 0 si alguna falla
make capture   # pcaps por interfaz en captures/ mientras el UE se vuelve a registrar
make down      # para todo y conserva la base de suscriptores (make clean también la borra)
make bler      # simulación BLER vs SNR de LDPC y Polar con la PHY de srsRAN (sin tocar la red, ~3 min)
make measure   # TBS reales del scheduler + barrido de MCS fijo + barrido de BW 10/15/20 (~35 min)
make analysis  # tablas, gráficas y results/analysis/resumen.md a partir de results/raw/
```

Otros comandos:

- **Ancho de banda:** `BW=15 make up` o `BW=20 make up`. Por defecto son 10 MHz (`BW_MHZ` en `.env`).
- **Consolas:** `make attach-gnb` / `make attach-ue` (tecla `t` = métricas de MCS, CQI, BLER y
  throughput; salir con `Ctrl-p Ctrl-q`).
- **WebUI de suscriptores:** http://127.0.0.1:3000 (`admin` / `1423`).
- **Tráfico desde el UE:** `docker exec ue ping 10.88.4.10`,
  `docker exec ue iperf3 -c 10.88.4.10 [-R] [-u -b 10M]` o `docker exec ue ping 8.8.8.8` (Internet).

## Modo distribuido: core y gNB en una Raspberry Pi 5, UE en el PC

La misma red repartida en dos equipos unidos por un cable Ethernet. En la Pi corren los 13 contenedores
del core y el gNB; en el PC solo el UE. Lo que cruza el cable es la "radio": las muestras IQ que gNB y
UE se pasan por ZMQ. N2, N3, N4 y el SBI se quedan dentro de la Pi. Así se ve que el UE llega al core y
a Internet aunque esté en otra máquina.

```
 PC (x86, 10.42.0.1)                      cable Ethernet               Raspberry Pi 5 (ARM64, 10.42.0.28)
 ┌──────────────┐  UL: UE publica en 10.42.0.1:2001  ──────────────▶  ┌─────┐ N2/N3 ┌──────────────────┐
 │ ue (srsUE)   │                                                     │ gnb │──────▶│ core Open5GS (13)│──▶ Internet
 └──────────────┘  ◀──────────────  DL: gNB publica en 10.42.0.28:2000 └─────┘       └──────────────────┘   (vía el PC)
```

Requisitos adicionales:

- Raspberry Pi 5 con Raspberry Pi OS 64 bits (probado: Debian 12, kernel 6.6, 8 GB) y Docker con Compose v2.
- SSH sin contraseña desde el PC hacia la Pi con un alias en `~/.ssh/config` (por defecto `pi-cable`;
  otro alias con `PI_HOST=<alias> make split-up`). Las IP de cada lado se sacan de ese alias.
- La Pi necesita salir a Internet para compilar (en nuestro caso, por el mismo cable, con la conexión
  compartida del PC).

```bash
make split-build    # copia el repo a la Pi y compila allá las imágenes ARM64 (~1 h la 1.ª vez)
make split-up       # core (Pi) -> gNB (Pi) -> UE (PC); espera la sesión PDU
make split-verify   # las mismas 29 comprobaciones contra los dos equipos + ping a 8.8.8.8 desde el UE
make split-logs     # últimas líneas de amf/smf/upf/gnb (Pi) y ue (PC)
make split-down     # apaga los dos lados (conserva la base de suscriptores en la Pi)
```

Para mostrarlo paso a paso con comandos manuales (qué correr en la Pi y qué en el PC), ver
[`DEMO-DISTRIBUIDO.md`](DEMO-DISTRIBUIDO.md).

Qué cambia respecto al modo de un solo PC:

- `gradiant/open5gs` solo existe para x86, así que en la Pi se compilan Open5GS y su WebUI desde el
  código, en el mismo tag v2.7.7 (`images/open5gs`, `images/open5gs-webui`). El gNB es la misma imagen
  de siempre compilada en la Pi, con `MARCH=armv8.2-a+dotprod+fp16` (Cortex-A76).
- `docker-compose.split-pi.yml` y `docker-compose.split-pc.yml` se cargan encima de `docker-compose.yml`
  y solo cambian los `device_args` de ZMQ (por línea de comandos) y publican los puertos 2000/2001 en
  el cable. `split-pi.env` elige las imágenes ARM64 y reparte los 4 núcleos de la Pi (core 0-1, gNB 2-3).
- Solo el perfil de 10 MHz (11.52 Msps, la tasa más baja que acepta srsUE).
- WebUI en `http://10.42.0.28:3000` desde el PC.

Resultados (2026-10-22, PC con adaptador USB RTL8152 de **100 Mbit/s**):

| Prueba | Resultado |
|---|---|
| `make split-up && make split-verify` | 29/29 + ping a 8.8.8.8 desde el UE (0 % de pérdida) |
| Tráfico ZMQ en el cable, en reposo | ~86 Mbit/s en cada sentido (el enlace va lleno) |
| ping UE → DN, 20 paquetes | 0 % de pérdida, RTT 103 / 174 / 339 ms (mín / medio / máx) |
| ping UE → 8.8.8.8 | 0 % de pérdida, ~280 ms |
| iperf3 TCP DL / UL | 2.68 / 2.76 Mbit/s |
| CPU del gNB en la Pi | ~1.2 núcleos |

ZMQ no tiene reloj propio: gNB y UE avanzan al ritmo al que llegan las muestras. A 10 MHz necesitan
11.52 Msps × 8 bytes ≈ 737 Mbit/s por sentido y el cable da ~86, así que la radio simulada corre unas
8.6 veces más lenta que el tiempo real. Por eso el throughput cae unas 10 veces y la latencia sube, pero
los temporizadores de registro alcanzan y todo el plano de control y de usuario funciona. Con un
adaptador gigabit (USB 3) el enlace dejaría de ser el cuello de botella.

## Parámetros de la red

Deben coincidir en todos los componentes; `make verify` comprueba su coherencia en el nivel V0.

| Parámetro | Valor |
|---|---|
| PLMN | `001/01` (PLMN de pruebas) |
| TAC / S-NSSAI / DNN | `7` / SST `1` / `internet` (IPv4) |
| Banda | n3 FDD, `dl_arfcn 368500` (DL 1842.5 MHz, UL 1747.5 MHz), SCS 15 kHz |
| Perfiles de BW | 10 MHz (52 PRB, 11.52 Msps) · 15 MHz (79 PRB, 15.36 Msps) · 20 MHz (106 PRB, 23.04 Msps) |
| SSB ARFCN | 368410 en los tres perfiles (`up.sh` lo compara con lo que imprime el gNB) |
| CORESET#0 | índice 6 a 10/15 MHz, índice 12 a 20 MHz (los que soporta srsUE) |
| Seguridad NAS | integridad NIA2, cifrado NEA0 (ver nota) |
| UE | IMSI `001010123456780`, K `00112233445566778899aabbccddeeff`, OPc `63BFA50EE6523365FF14C1F45F88737D` |

Las claves son las públicas de los tutoriales de srsRAN y solo valen para simulación.

## Resultados verificados (2026-10-10, Ryzen 7 5825U, gobernador `powersave`)

| Prueba | Resultado |
|---|---|
| `make up && make verify` desde cero (`down --volumes`) | 29/29 en ~33 s |
| ping UE → DN, 10 paquetes | 0 % de pérdida, RTT 21 / 29 / 38 ms (mín / medio / máx) |
| iperf3 UDP UL 10 Mbit/s, 10 MHz | 9.92 Mbit/s, 0 % de pérdida, jitter 1.7 ms |
| iperf3 TCP DL / UL, 10 MHz | 26.2 / 29.7 Mbit/s |
| iperf3 TCP DL, 20 MHz | 46.4 Mbit/s |
| ping UE → 8.8.8.8 (Internet por la red 5G) | 0 % de pérdida, ~48 ms |
| Captura en N3 | ICMP del UE (10.99.0.2) encapsulado en GTP-U entre gNB y UPF (TEID 0x2f8) |

## Codificación y rendimiento (rúbrica C2 y C3)

Detalle en `docs/analisis-codificacion.md` y `docs/rendimiento.md`. Datos crudos en `results/raw/` y
tablas y figuras en `results/analysis/`.

| Resultado | Valor |
|---|---|
| TBS calculado (TS 38.214) vs scheduler del gNB | 213/213 asignaciones idénticas byte a byte |
| SNR para BLER 10 % (AWGN, PHY de srsRAN) | MCS 0: −5.5 dB · MCS 9: 3.7 dB · MCS 28: 21.2 dB (1.4-4.8 dB por encima de Shannon) |
| Canal ZMQ | SNR de PUSCH 65 dB → CQI 15, MCS 28 en DL y UL, 0 % de NACK |
| MAC / TCP, 10 MHz | DL 28.1 / 26.4 · UL 33.2 / 30.1 Mbit/s (TBS×1000: 31.8 / 33.8) |
| MAC / TCP, 20 MHz | DL 58.3 / 45.1 · UL 72.4 / 46.5 Mbit/s |
| 15 MHz | el DL no mejora (PDSCH limitado a los 48 RB de CORESET#0 con DCI 1_0); el UL sí (52 Mbit/s) |
| RTT | 29 ms en reposo (0.1 ms es la parte cableada); ~180 ms con el DL saturado (cola del gNB) |

## Validación RF con HackRF One (gNB real con USRP)

Cuando el gNB transmite con una USRP, una HackRF One conectada a este PC actúa como receptor
independiente para comprobar que la señal sale bien. La HackRF **solo recibe**: es half-duplex y
no tiene transmisión/recepción temporizada, así que no puede ser el radio del gNB. Corre nativo en
el host (Docker Desktop no pasa USB): `brew install hackrf` en macOS o `apt install hackrf` en Linux.

> Conexión por cable con 30-60 dB de atenuación entre la salida TX de la USRP y la HackRF, o con
> antenas dentro de una caja blindada. La entrada de la HackRF admite ~-5 dBm como máximo.

```bash
make rf-selftest                     # prueba el analizador con una señal NR sintética (sin hardware)
make rf-info                         # ¿la HackRF está conectada?
GNB_CFG=/ruta/gnb_usrp.yml make rf-params   # frecuencias que se van a revisar
GNB_CFG=/ruta/gnb_usrp.yml make rf-sweep    # barrido alrededor de la portadora
GNB_CFG=/ruta/gnb_usrp.yml SSB_ARFCN=<dl_ssb_arfcn del log del gNB> make rf-check   # captura + análisis
```

`rf-check` captura 1 s de muestras IQ centradas en la portadora y comprueba: que hay un SSB (PSS),
el PCI (PSS + SSS) frente al configurado, la frecuencia del SSB y su error en ppm, el periodo de las
ráfagas SSB, el ancho ocupado y la saturación. Deja `report.md`, `report.json` y las figuras en
`results/rf/<fecha>/`. Ganancias: `LNA` (0-40), `VGA` (0-62) y `AMP` (0/1, apagado por defecto).

## gNB con radio real: USRP B200/B210 (solo core + gNB)

El mismo gNB (srsRAN 24.10.1) puede transmitir con una USRP B200/B210 conectada por USB 3 en vez de ZMQ.
La celda es idéntica (n3, 1842.5 MHz DL / 1747.5 MHz UL, PLMN 00101, TAC 7, PCI 1); solo cambia el bloque
`ru_sdr` de `configs/gnb/gnb_usrp_<BW>mhz.yml` (generado por `scripts/gen-radio-configs.sh`).

```bash
make usrp-build    # imagen siscom/gnb-uhd:24.10.1 (UHD 4.1 + firmware/FPGA de la B2xx), ~10 min
make usrp-probe    # detecta la USRP desde el contenedor: debe decir "Operating over USB 3"
./usrp-start.sh    # detecta la USRP, exige USB 3, (construye la imagen si falta), core -> gNB, 20 s de estabilidad
                   # (BW=10|15|20; ALLOW_USB2=1 para forzar USB 2). Equivale a make usrp-up
make usrp-logs     # últimas líneas del gNB;  docker attach gnb-usrp (t = métricas)
./usrp-stop.sh     # apaga el gNB (deja de transmitir); el core sigue. --all apaga también el core
```

- Ganancias por defecto: TX 80 dB (~ 0 dBm), RX 40 dB. Por aire una HackRF a pocos cm recibe <= -12 dBm
  (su máximo es -5 dBm); por cable siempre con 30-60 dB de atenuadores. Cambiarlas al arrancar con
  `USRP_TX_GAIN=.. USRP_RX_GAIN=.. ./usrp-start.sh` (máximo TX 89.75 ~ +10 dBm).
- El contenedor recibe todo `/dev/bus/usb` (la B2xx se re-enumera de USB 2 a USB 3 al cargar el firmware).
- Algún `Underflow: 1` esporádico en consola es normal con el gobernador de CPU en `powersave`;
  con `performance` desaparecen casi del todo.
- Verificado 2026-10-29 con una B200 (USB 3): NG Setup aceptado, `==== gNB started ===`, Late 0 / Overflow 0,
  ~1 underflow cada 10-15 s, gNB ~1.3 núcleos y 2.2 GiB.

## Decisiones y problemas resueltos

| Problema | Causa | Solución |
|---|---|---|
| `[upf] ERROR: Invalid packet [IP version:6]` en cada registro | `tun_srsue` envía un Router Solicitation IPv6 y la sesión es solo IPv4 | IPv6 desactivado dentro del contenedor del UE (`sysctls` en compose) |
| El UE se registra y luego recibe `RRC Release` tras 3 s | srsUE 25.10 no descifra NAS con NEA2: el Registration Accept se decodifica como basura (`Unsupported extended protocol discriminator`) y el gNB expira esperando la sesión PDU | AMF con `ciphering_order: [NEA0, NEA1, NEA2]`, el orden por defecto de Open5GS. La integridad NIA2 se mantiene |
| `Unable to derive a valid SSB pointA ... CORESET#0 index=12` a 10 MHz | El índice 12 ocupa 96 RB y solo cabe en 20 MHz | Índice 6 (48 RB) a 10 y 15 MHz (TS 38.213, tabla 13-1) |
| 5 MHz no funciona | Con 25 PRB solo caben CORESET#0 de 24 RB (índices 0-5) y srsUE no encuentra la celda con ellos | Perfil de 5 MHz descartado |
| La imagen de srsUE quedaba sin binario | srsRAN 4G define `CMAKE_SKIP_INSTALL_ALL_DEPENDENCY` | `make srsue srsran_rf_zmq` antes de `make install` |
| `[channel.dl.awgn]` de srsUE no añade ruido en 5G SA | El emulador de canal solo está conectado en la ruta LTE (`sync.cc`, no `sync_sa.cc`) | El canal se estudia offline con `make bler` (imagen `phy-sim`) |
| `polar_chain_test` aborta (`double free`) con E < N | Bug de la prueba upstream: recorre `BATCH_SIZE*N` LLR en un buffer de `BATCH_SIZE*E` | Parche con `sed` en `images/phy-sim/Dockerfile` |
| La WebUI no permitía iniciar sesión | En producción no crea `admin`, y un hash sembrado a mano no es PBKDF2 válido | `up.sh` crea el admin con `Account.register` de la propia WebUI |
| En la Pi, `gradiant/open5gs` no arranca | La imagen solo se publica para amd64 | `images/open5gs` y `images/open5gs-webui` compilan v2.7.7 en ARM64 |
| gNB en ARM64: `unknown value 'native+crypto' for '-march'` | En aarch64 el CMake de srsRAN añade `+crypto` a `MARCH` | `MARCH=armv8.2-a+dotprod+fp16` en `scripts/split.sh` |
| `split-verify`: `kex_exchange_identification: Connection reset by peer` | `docker compose ps` remoto abre una sesión SSH por contenedor y supera `MaxStartups` de la Pi | Contar contenedores con un solo `docker ps` en `verify.sh` |
| 5G-AKA fallaba con HTTP 500 | Campos numéricos del suscriptor guardados como `double` | `NumberInt`/`NumberLong` en `configs/open5gs/mongo-init.js` |

## Estructura

```
docker-compose.yml       servicios, redes y volúmenes (gnb/ue en el perfil "ran", tools en "capture")
docker-compose.split-*.yml, split-pi.env   modo distribuido (core+gNB en la Pi, UE en el PC)
.env                     versiones, ancho de banda y reparto de CPU
images/                  Dockerfiles: gnb, srsue, dn (iperf3), tools (tcpdump/tshark), phy-sim (BLER/Polar),
                         open5gs y open5gs-webui (ARM64, para la Pi)
configs/open5gs/         YAML de cada NF + mongo-init.js (suscriptor)
configs/gnb, configs/ue  generados con scripts/gen-radio-configs.sh (no editar a mano)
configs/gnb/gnb_overrides.yml  2.º archivo del gNB (MCS fijo, métricas); measure.sh pone el suyo
scripts/                 up.sh, verify.sh, split.sh (modo distribuido), capture.sh, down.sh, upf-entrypoint.sh, gen-radio-configs.sh,
                         rf/rf.sh y rf/rf_analyze.py (validación RF con HackRF),
                         measure.sh (mediciones), analysis/bler.sh y analysis/throughput.py (análisis)
docs/                    analisis-codificacion.md (MCS, LDPC/Polar) y rendimiento.md (medidas y análisis)
results/raw/             datos crudos de las mediciones; results/analysis/ CSVs, figuras y resumen.md
results/rf/              capturas HackRF (los .iq se ignoran) con su report.md y figuras
captures/ logs/          artefactos de ejecución (ignorados por git)
```

Para diagnosticar problemas: `LOG_LEVEL=info scripts/gen-radio-configs.sh && make up` y revisar
`logs/gnb.log` y `logs/ue.log`.
