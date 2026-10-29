#!/usr/bin/env bash
# Generates gNB/UE ZMQ configs for each bandwidth profile (band n3, SCS 15 kHz).
# Profile: <bw_mhz> <srate_mhz> <nof_prb> <ssb_nr_arfcn> <coreset0_index>
# coreset0_index (TS 38.213 Table 13-1, 15/15 kHz): 12 = 96 RB @20 MHz (official srsUE tutorial),
# 6 = 48 RB @10/15 MHz (official multi-UE tutorial). 5 MHz is not offered: only CORESET#0 0-5
# (24 RB, 2-3 symbols) fit in 25 PRB and srsUE 25.10 never finds the cell with them (tested).
# ssb_nr_arfcn: value printed by the gNB as dl_ssb_arfcn (368410 for 10, 15 and 20 MHz, verified).
set -euo pipefail
LOG_LEVEL="${LOG_LEVEL:-warning}"   # gNB/UE file log level (info or debug for troubleshooting)
USRP_TX_GAIN="${USRP_TX_GAIN:-60}"  # USRP gains (dB). B210 TX 0-89.75: 60 ~ -20 dBm, enough for a nearby phone
USRP_RX_GAIN="${USRP_RX_GAIN:-40}"  # B210 RX 0-76
cd "$(dirname "$0")/../configs"

# ru_sdr block of gnb_usrp_<bw>mhz.yml (real USRP B200/B210 over USB 3 instead of ZMQ).
usrp_block() {
cat <<EOF
ru_sdr:                             # "Radio Unit" por SDR: una USRP B200/B210 real conectada por USB 3
  device_driver: uhd                # driver UHD de Ettus (imagen siscom/gnb-uhd, compilada con ENABLE_UHD=ON)
  device_args: type=b200,num_recv_frames=64,num_send_frames=64
                                    # type=b200: busca una B200 o B210 (UHD usa el mismo tipo para ambas)
                                    # num_*_frames: más buffers USB para evitar overflows (O) y underflows (U)
  clock: internal                   # referencia de 10 MHz: oscilador interno de la USRP (sin GPSDO ni reloj externo)
  sync: internal                    # señal PPS interna (no hay que sincronizar con otra radio)
  srate: ${1}                      # tasa de muestreo en MHz (${1} Msps alcanza para ${2} PRB = ${3} MHz)
  otw_format: sc12                  # muestras de 12 bits por el USB (menos ancho de banda que sc16, mismo resultado)
  tx_gain: ${USRP_TX_GAIN}                      # ganancia TX en dB (B210: 0-89.75). 60 ~ -20 dBm a 1.8 GHz; subir con
                                    # antenas y teléfono lejos, bajar si va por cable (siempre con atenuadores)
  rx_gain: ${USRP_RX_GAIN}                      # ganancia RX en dB (B210: 0-76); muy alta satura con el UE cerca
EOF
}
while read -r bw sr prb ssb cs0; do
cat > "gnb/gnb_zmq_${bw}mhz.yml" <<EOF
# =====================================================================================================
# gNB srsRAN Project (release_24_10_1) - celda NR banda n3 FDD, ${bw} MHz, SCS 15 kHz, radio por ZMQ.
# GENERADO por scripts/gen-radio-configs.sh: no editar a mano (se sobrescribe). Cambia el script.
# Base: config oficial del tutorial "srsRAN gNB with srsUE" (srsRAN_Project_docs, gnb_zmq.yaml).
# Referencia de todas las claves: ./gnb --help (o docs.srsran.com/projects/project, "Configuration Reference")
# =====================================================================================================
cu_cp:                              # CU-CP: plano de control del gNB (RRC, NGAP hacia el AMF)
  amf:
    addr: 10.88.2.2                 # IP del AMF (red ran). Aquí se abre la asociación SCTP de N2
    port: 38412                     # puerto estándar de NGAP (TS 38.412)
    bind_addr: 10.88.2.20           # IP local del gNB en la red ran (origen de N2)
    supported_tracking_areas:       # áreas que el gNB anuncia al AMF en el NG Setup Request
      - tac: 7                      # Tracking Area Code: debe existir en amf.yaml (tai)
        plmn_list:
          - plmn: "00101"           # PLMN = MCC 001 + MNC 01 (red de pruebas)
            tai_slice_support_list:
              - sst: 1              # slice eMBB soportado en esta área (debe estar en amf.yaml plmn_support)
  inactivity_timer: 7200            # s sin tráfico antes de liberar al UE (7200 = máximo, para que no se caiga)

cu_up:                              # CU-UP: plano de usuario del gNB (SDAP/PDCP y GTP-U hacia el UPF)
  upf:
    bind_addr: 10.88.2.20           # IP local para N3 (GTP-U, UDP 2152) en la red ran

ru_sdr:                             # "Radio Unit" por SDR. Aquí está el truco de la simulación:
  device_driver: zmq                # en vez de un USRP (uhd), las muestras IQ viajan por ZeroMQ/TCP
  device_args: tx_port=tcp://10.88.3.20:2000,rx_port=tcp://10.88.3.21:2001,base_srate=${sr}e6
                                    # tx_port: donde el gNB ENTREGA sus muestras de bajada (DL) -> el UE las lee
                                    # rx_port: donde el gNB LEE las muestras de subida (UL) que publica el UE
                                    # base_srate: tasa de muestreo base; debe ser IGUAL en el UE
  srate: ${sr}                      # tasa de muestreo en MHz (${sr} Msps alcanza para ${prb} PRB = ${bw} MHz)
  tx_gain: 75                       # ganancia TX en dB (en ZMQ no hay amplificador real; valor del tutorial)
  rx_gain: 75                       # ganancia RX en dB (ídem)

cell_cfg:                           # parámetros de la celda NR que el gNB emite
  dl_arfcn: 368500                  # NR-ARFCN de bajada: F = 368500 x 5 kHz = 1842.5 MHz (TS 38.104 §5.4.2)
  band: 3                           # banda n3 (1800 MHz, FDD: UL 1710-1785 / DL 1805-1880 MHz)
  channel_bandwidth_MHz: ${bw}      # ancho de banda del canal -> ${prb} PRB a 15 kHz (TS 38.101-1 tabla 5.3.2-1)
  common_scs: 15                    # separación entre subportadoras 15 kHz (numerología mu=0; srsUE solo soporta 15)
  plmn: "00101"                     # PLMN que la celda difunde en el SIB1
  tac: 7                            # TAC que difunde la celda (igual que arriba y que en amf.yaml)
  pci: 1                            # Physical Cell ID (0-1007): identifica la celda en la capa física
  pdcch:                            # canal de control de bajada (por donde llegan las asignaciones DCI)
    common:
      ss0_index: 0                  # Search Space #0 (TS 38.213 tabla 13-11): valor que srsUE soporta
      coreset0_index: ${cs0}             # CORESET#0 (TS 38.213 tabla 13-1): bloque de RBs/símbolos para el PDCCH
                                    # inicial. 12 = 96 RB (20 MHz); 6 = 48 RB (10/15 MHz). Debe caber en el BW
    dedicated:
      ss2_type: common              # srsUE solo decodifica el espacio de búsqueda común
      dci_format_0_1_and_1_1: false # usa DCI "fallback" 0_0/1_0 (srsUE no soporta 0_1/1_1)
  prach:
    prach_config_index: 1           # configuración del preámbulo de acceso aleatorio (TS 38.211 tabla 6.3.3.2-2);
                                    # 1 = formato 0 FDD, el que espera srsUE
  pdsch:
    mcs_table: qam64                # tabla MCS 1, hasta 64QAM (TS 38.214 tabla 5.1.3.1-1). qam256 no serviría: con DCI 1_0
                                    # (la única que srsUE decodifica) TS 38.214 §5.1.3.1 obliga a usar la tabla 1
  pusch:
    mcs_table: qam64                # tabla MCS de subida hasta 64QAM (con DCI 0_0 también rige la tabla 1)

log:
  filename: /logs/gnb.log           # log detallado (montado en 5GDockerNetwork/logs/gnb.log)
  all_level: ${LOG_LEVEL}           # warning normal; info/debug para diagnosticar (LOG_LEVEL=info al generar)
  hex_max_size: 0                   # no volcar mensajes en hexadecimal

pcap:                               # capturas generadas por el propio gNB (montadas en captures/)
  mac_enable: true                  # capa MAC (ver en Wireshark con el disector mac-nr)
  mac_filename: /captures/gnb_mac.pcap
  ngap_enable: true                 # NGAP (N2) tal como lo ve el gNB
  ngap_filename: /captures/gnb_ngap.pcap
EOF
# Same cell, real radio: copy the ZMQ gNB config replacing the header line and the ru_sdr block.
awk -v blk="$(usrp_block "$sr" "$prb" "$bw")" '
  /radio por ZMQ\.$/ { sub(/radio por ZMQ\./, "radio USRP B200/B210 (UHD).") }
  /^ru_sdr:/ { print blk; print ""; skip = 1; next }
  skip && /^[a-z_]+:/ { skip = 0 }
  !skip' "gnb/gnb_zmq_${bw}mhz.yml" > "gnb/gnb_usrp_${bw}mhz.yml"
cat > "ue/ue_zmq_${bw}mhz.conf" <<EOF
# =====================================================================================================
# srsUE (srsRAN 4G release_25_10) como UE 5G SA, banda n3, ${bw} MHz (${prb} PRB), radio por ZMQ.
# GENERADO por scripts/gen-radio-configs.sh: no editar a mano (se sobrescribe). Cambia el script.
# Formato INI; los comentarios van en la línea ANTERIOR a cada clave.
# Base: ue_zmq.conf del tutorial oficial + srsue/ue.conf.example de srsRAN 4G (todas las claves explicadas).
# =====================================================================================================

# ---------- [rf] radio: aquí se sustituye la antena por ZeroMQ --------------------------------------
[rf]
# corrección de frecuencia en Hz (0: en ZMQ no hay error de oscilador)
freq_offset = 0
# ganancias en dB (en ZMQ no hay hardware; valores del tutorial)
tx_gain = 50
rx_gain = 40
# tasa de muestreo en muestras/s: IGUAL que srate del gNB
srate = ${sr}e6
# una antena (1T1R, igual que el gNB)
nof_antennas = 1
# driver de radio: zmq (en Fase 2 sería uhd para un USRP)
device_name = zmq
# tx_port: donde el UE ENTREGA sus muestras de subida (el gNB las lee); rx_port: lee la bajada del gNB.
# Puertos cruzados respecto al gNB (tx del uno = rx del otro). base_srate igual en ambos.
device_args = tx_port=tcp://10.88.3.21:2001,rx_port=tcp://10.88.3.20:2000,base_srate=${sr}e6

# ---------- [rat.eutra] LTE: desactivado -------------------------------------------------------------
[rat.eutra]
# portadora LTE (no se usa porque nof_carriers = 0)
dl_earfcn = 2850
# 0 portadoras LTE = el UE funciona solo en 5G (modo SA)
nof_carriers = 0

# ---------- [rat.nr] 5G NR ---------------------------------------------------------------------------
[rat.nr]
# banda NR a buscar (n3)
bands = 3
# 1 portadora NR
nof_carriers = 1
# NR-ARFCN central de bajada: igual que dl_arfcn del gNB (1842.5 MHz)
dl_nr_arfcn = 368500
# NR-ARFCN del bloque de sincronización (SSB). DEBE ser el dl_ssb_arfcn que imprime el gNB
# (368410 en 10/15/20 MHz con nuestros CORESET#0); si no, el UE se queda en "Attaching..."
ssb_nr_arfcn = ${ssb}
# ancho de banda en PRB (${bw} MHz = ${prb} PRB a 15 kHz)
max_nof_prb = ${prb}
nof_prb = ${prb}

# ---------- [pcap] capturas propias del UE ------------------------------------------------------------
[pcap]
# capas a capturar: MAC NR y NAS (mensajes de registro/sesión, se ven en Wireshark)
enable = mac_nr,nas
mac_nr_filename = /captures/ue_mac_nr.pcap
nas_filename = /captures/ue_nas.pcap

# ---------- [log] ------------------------------------------------------------------------------------
[log]
# nivel de log por capa (warning normal; info para diagnosticar)
all_level = ${LOG_LEVEL}
# log de la librería PHY (muy verboso): apagado
phy_lib_level = none
# bytes máximos de hexdump por mensaje
all_hex_limit = 32
# archivo de log (montado en 5GDockerNetwork/logs/ue.log)
filename = /logs/ue.log
# -1 = sin límite de tamaño
file_max_size = -1

# ---------- [usim] la "SIM" por software: DEBE coincidir con el suscriptor de mongo-init.js -----------
[usim]
# soft = SIM simulada en software (en Fase 2: pcsc = lector de tarjetas con SIM real)
mode = soft
# algoritmo de autenticación 3GPP Milenage (el que usa 5G-AKA en Open5GS)
algo = milenage
# OPc: constante del operador combinada con K
opc  = 63BFA50EE6523365FF14C1F45F88737D
# K: clave secreta de 128 bits del suscriptor
k    = 00112233445566778899aabbccddeeff
# IMSI = MCC 001 + MNC 01 + MSIN 0123456780
imsi = 001010123456780
# IMEI del "teléfono" (identificador del equipo, no del suscriptor)
imei = 353490069873319

# ---------- [rrc] ------------------------------------------------------------------------------------
[rrc]
# versión 3GPP que el UE declara (Release 15 = primera de 5G)
release = 15
# categoría de UE declarada (capacidades)
ue_category = 4

# ---------- [nas] sesión de datos ---------------------------------------------------------------------
[nas]
# DNN (APN en 4G) que pide el UE: igual que en smf.yaml y en el suscriptor
apn = internet
# tipo de sesión: solo IPv4 (el pool del SMF es IPv4)
apn_protocol = ipv4

# ---------- [gw] interfaz IP del UE dentro del contenedor ---------------------------------------------
[gw]
# nombre de la interfaz TUN donde aparece la IP del UE (10.99.x.y)
ip_devname = tun_srsue
# máscara del pool 10.99.0.0/16
ip_netmask = 255.255.0.0

[gui]
# interfaz gráfica de srsUE: no compilada en la imagen
enable = false

# ---------- [channel.*] emulador de canal (ruido/desvanecimiento sobre las muestras ZMQ) -------------
[channel.dl]
# desactivado: canal ideal. Se activará para los barridos de SNR (análisis MCS/LDPC)
enable = false

[channel.dl.awgn]
# ruido blanco gaussiano con la SNR indicada en dB
enable = false
snr = 30
EOF
done <<'PROFILES'
10 11.52 52 368410 6
15 15.36 79 368410 6
20 23.04 106 368410 12
PROFILES
echo "generated: $(ls gnb ue | tr '\n' ' ')"
