# 5GDockerNetwork — Red 5G SA simulada en Docker (SISCOM2, Fase 1)

Red 5G Standalone completa en un solo PC y **toda en contenedores**:

- **Core 5G: Open5GS 2.7.7**, con una función de red (NF) por contenedor (enfoque NFV/CNF).
- **gNB: srsRAN Project `release_24_10_1`**, monolítico (CU+DU).
- **UE: srsUE** (srsRAN 4G `release_25_10`), con USIM por software.
- **Radio simulada con ZeroMQ**: gNB y UE intercambian muestras IQ por TCP. Toda la pila NR se ejecuta
  de verdad: PHY con LDPC/Polar, MAC, RLC, PDCP, RRC y NAS.

No se instala nada en el host aparte de Docker, ni se tocan sus rutas, `iptables` ni `sysctl`.

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
```

Otros comandos:

- **Ancho de banda:** `BW=15 make up` o `BW=20 make up`. Por defecto son 10 MHz (`BW_MHZ` en `.env`).
- **Consolas:** `make attach-gnb` / `make attach-ue` (tecla `t` = métricas de MCS, CQI, BLER y
  throughput; salir con `Ctrl-p Ctrl-q`).
- **WebUI de suscriptores:** http://127.0.0.1:3000 (`admin` / `1423`).
- **Tráfico desde el UE:** `docker exec ue ping 10.88.4.10`,
  `docker exec ue iperf3 -c 10.88.4.10 [-R] [-u -b 10M]` o `docker exec ue ping 8.8.8.8` (Internet).

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

## Decisiones y problemas resueltos

| Problema | Causa | Solución |
|---|---|---|
| El UE se registra y luego recibe `RRC Release` tras 3 s | srsUE 25.10 no descifra NAS con NEA2: el Registration Accept se decodifica como basura (`Unsupported extended protocol discriminator`) y el gNB expira esperando la sesión PDU | AMF con `ciphering_order: [NEA0, NEA1, NEA2]`, el orden por defecto de Open5GS. La integridad NIA2 se mantiene |
| `Unable to derive a valid SSB pointA ... CORESET#0 index=12` a 10 MHz | El índice 12 ocupa 96 RB y solo cabe en 20 MHz | Índice 6 (48 RB) a 10 y 15 MHz (TS 38.213, tabla 13-1) |
| 5 MHz no funciona | Con 25 PRB solo caben CORESET#0 de 24 RB (índices 0-5) y srsUE no encuentra la celda con ellos | Perfil de 5 MHz descartado |
| La imagen de srsUE quedaba sin binario | srsRAN 4G define `CMAKE_SKIP_INSTALL_ALL_DEPENDENCY` | `make srsue srsran_rf_zmq` antes de `make install` |
| La WebUI no permitía iniciar sesión | En producción no crea `admin`, y un hash sembrado a mano no es PBKDF2 válido | `up.sh` crea el admin con `Account.register` de la propia WebUI |
| 5G-AKA fallaba con HTTP 500 | Campos numéricos del suscriptor guardados como `double` | `NumberInt`/`NumberLong` en `configs/open5gs/mongo-init.js` |

## Estructura

```
docker-compose.yml       servicios, redes y volúmenes (gnb/ue en el perfil "ran", tools en "capture")
.env                     versiones, ancho de banda y reparto de CPU
images/                  Dockerfiles: gnb, srsue, dn (iperf3), tools (tcpdump/tshark)
configs/open5gs/         YAML de cada NF + mongo-init.js (suscriptor)
configs/gnb, configs/ue  generados con scripts/gen-radio-configs.sh (no editar a mano)
scripts/                 up.sh, verify.sh, capture.sh, down.sh, upf-entrypoint.sh, gen-radio-configs.sh
captures/ logs/          artefactos de ejecución (ignorados por git)
```

Para diagnosticar problemas: `LOG_LEVEL=info scripts/gen-radio-configs.sh && make up` y revisar
`logs/gnb.log` y `logs/ue.log`.
