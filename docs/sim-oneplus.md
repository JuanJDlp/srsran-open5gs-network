# SIM física y celular comercial (OnePlus) contra el gNB con USRP

Evidencia de la programación de la SIM del laboratorio y guía para conectar un celular 5G comercial
(OnePlus) a la celda real del gNB con USRP B200/B210 (`./usrp-start.sh`). Programada el 2026-11-07.

## 1. Programación de la SIM

**Herramienta:** `GRSIMWrite.exe` v4.4.4+ ("SIM Personalize tools", BOMFLORE), lector PC/SC
*Alcor Micro USB Smart Card Reader*, en Windows 10.

**Tarjeta:** SIM programable BOMFLORE, `Type: LTE(LY14):LTE+GSM`,
ATR `3B9F95801FC78031A073B6A10067CF3215CA9CD70920`. Llegó en blanco (ICCID e IMSI en `FFFF…`).

### Valores escritos

| Campo (GRSIMWrite) | Valor | De dónde sale en el repo |
|---|---|---|
| ICCID | `89001010123456780000` | Libre (la tarjeta venía sin ICCID). `89` = telecom, `00101` = PLMN de pruebas |
| IMSI15 (GSM y LTE) | `001010123456780` | `imsi` en `configs/open5gs/mongo-init.js` |
| Ki (GSM y LTE) | `00112233445566778899AABBCCDDEEFF` | `security.k` en `mongo-init.js` |
| OPc (opción **OPC**, no OP) | `63BFA50EE6523365FF14C1F45F88737D` | `security.opc` en `mongo-init.js` |
| Algoritmo | Milenage (GSM y LTE) | Open5GS usa 5G-AKA/EPS-AKA con Milenage |
| PLMN / EHPLMN | `00101` | `mcc: 001`, `mnc: 01` en `configs/open5gs/amf.yaml` |
| HPLMNwAct | `00101:4800; 00101:8000; 00101:0080` | `4800` = E-UTRAN + **NG-RAN (5G)**; `8000` UTRAN; `0080` GSM |
| PLMNwAct / OPLMNwAct | `00101:4000; 00101:8000; 00101:0080` | Rellenado con el botón *Auto* |
| SPN | `SISCOM2` | Nombre que muestra el celular |
| ACC | `0001` | Calculado por la herramienta a partir del último dígito del IMSI |
| PIN1 / PIN2 | `1234` / `1234` | Por defecto de la tarjeta (PIN desactivado salvo que se active en el celular) |
| PUK1 / PUK2 | `88888888` | Por defecto de la tarjeta |
| ADM | `88888888` (hex `3838383838383838`) | Clave de administración por defecto de estas tarjetas BOMFLORE |

Se mantienen los valores por defecto de la herramienta en AD (`00000002`, MNC de 2 dígitos), HPLMN
search period (`50`), SMSP y las constantes Milenage (*R&C Para*).

### Procedimiento seguido

1. Abrir `GRSIMWrite.exe` **sin** "Ejecutar como administrador" (no hace falta para PC/SC).
2. *Read Card* → la tarjeta se lee en blanco.
3. Rellenar ICCID, IMSI15, Ki, OPc, SPN y el algoritmo Milenage en las dos columnas (GSM y LTE/WCDMA).
4. *Auto* en ambas columnas para generar PLMN/EHPLMN y las listas `PLMNwAct`.
5. En `HPLMNwAct` (botón `…` → *Modify*) cambiar la primera entrada de `4000` a `4800` para añadir NG-RAN.
6. *Write Card* → `Write Card Success!` (115/115 pasos).
7. *Read Card* de nuevo → ICCID, IMSI, PLMN, EHPLMN, listas `…wAct` y SPN coinciden con la tabla.

> **Ki y OPc no se pueden leer de vuelta.** Son de solo escritura en la tarjeta: la herramienta muestra
> lo que tiene en sus campos, no lo que hay en la SIM. Se confirman cuando el celular supera la
> autenticación 5G-AKA contra el core (ver §4).

### Cosas que la SIM no lleva (y por qué no hacen falta)

- **Ningún suscriptor nuevo en el core.** El IMSI `001010123456780` ya está sembrado en Mongo por
  `mongo-init.js`. Es el mismo que usa el srsUE simulado, así que **no** se deben tener el srsUE (modo
  ZMQ) y el celular registrados a la vez (el modo USRP no arranca srsUE).
- **SUCI con cifrado del SUPI.** La tarjeta no tiene ficheros 5GS de protección SUCI. El celular envía el
  SUCI con esquema *null* (el IMSI en claro), que es justo lo que acepta el core: Open5GS no tiene
  configurada ninguna clave de red doméstica (`hnet`).
- **SQN.** La SIM nueva y el `sqn: 0` del core no coinciden. En el primer intento el celular responde
  *Synch failure* (AUTS) y la red se resincroniza sola. Es normal ver un primer fallo en el log.

## 2. La celda a la que se tiene que conectar

| Parámetro | Valor | Archivo |
|---|---|---|
| Banda | **n3 FDD** (DL 1805-1880, UL 1710-1785 MHz) | `configs/gnb/gnb_usrp_<BW>mhz.yml` |
| Portadora DL | 1842.5 MHz (NR-ARFCN `368500`) | idem |
| SSB | NR-ARFCN `368410`, SCS 15 kHz | idem |
| Ancho de banda | 10 MHz por defecto (`BW=15` o `BW=20`) | `.env` |
| Modo | **5G SA** (sin ancla LTE) | — |
| PLMN / TAC / PCI | `00101` / `7` / `1` | `amf.yaml`, `gnb_usrp_*.yml` |
| Slice / DNN | SST `1` / `internet` (IPv4) | `mongo-init.js`, `smf.yaml` |
| IP del UE | `10.99.0.0/16` (la primera suele ser `10.99.0.2`), DNS `8.8.8.8` / `1.1.1.1`, MTU 1400 | `smf.yaml` |
| Seguridad NAS | Integridad NIA2, cifrado **NEA0** primero | `amf.yaml` |
| Nombre de red | `SISCOM2 5G Lab` (lo envía el AMF tras el registro) | `amf.yaml` |

## 3. Qué esperar en el laboratorio

**Requisito que manda sobre todo lo demás:** el modelo exacto de OnePlus debe soportar **n3 en modo SA**.
Muchos modelos tienen n3 solo para NSA, o SA solo en n78/n41. Si no lo soporta, el celular **no verá la
celda** aunque la SIM esté perfecta. Hay que comprobarlo en la ficha técnica del modelo y región
(p. ej. en *Ajustes → Acerca del dispositivo*, el modelo exacto, y buscar sus bandas NR SA).
El OnePlus del laboratorio (Nord CE 2 Lite 5G **CPH2409**) sí lista n3 en SA: ver §4.0.

Otros riesgos conocidos, de más a menos probable:

1. **El celular no busca SA en una red que no conoce.** Algunos firmwares solo activan SA para operadores
   de una lista. En ese caso hay que forzar NR (ver §4.2) o probar otro modelo.
2. **Potencia.** Con `tx_gain: 80` (~0 dBm) el alcance es de pocos metros. Hay que poner el celular cerca de
   la antena TX de la USRP. Se puede subir con `USRP_TX_GAIN=85 ./usrp-start.sh` (máximo 89.75 ≈ +10 dBm),
   pero hay que apartar la HackRF si está recibiendo por aire.
3. **Cifrado NEA0.** El core prefiere NAS sin cifrado (necesario para srsUE). La gran mayoría de celulares lo
   aceptan; si alguno lo rechazara se vería un *Security Mode Reject* en el AMF.
4. **Sin voz ni SMS.** No hay IMS. El celular puede mostrar "solo datos" o no tener VoNR; es lo esperado.

Secuencia normal, de principio a fin (unos segundos):

```
celular encuentra el SSB (PCI 1) → lee SIB1 (PLMN 00101, TAC 7) → RACH → RRC Setup
→ Registration Request (SUCI null) → Authentication (puede haber 1 Synch failure y reintento)
→ Security Mode (NIA2/NEA0) → Registration Accept → PDU Session Establishment (DNN internet)
→ IP 10.99.0.x → icono 5G y datos
```

## 4. Configuración del OnePlus

### 4.0 Equipo usado en el laboratorio

| Dato | Valor |
|---|---|
| Modelo | **OnePlus Nord CE 2 Lite 5G**, número de modelo **CPH2409** (variante global/Europa) |
| Procesador / módem | Qualcomm Snapdragon 695 5G, octa-core (módem X51 integrado) |
| Sistema | Android 14, OxygenOS 14.0 |
| Ranura usada | SIM1 (nombre mostrado: `SIM1`) |
| Bandas 5G NR (CPH2409) | SA y NSA: n1, n3, n5, n7, n8, n20, n28, n38, n40, n41, n66, n77, n78 |
| ¿Soporta la celda del lab? | **Sí, n3 en SA** según fichas técnicas del CPH2409 (no confirmado por el fabricante) |

> La variante de India (**CPH2381**) solo lista n1, n28, n41, n77 y n78: **sin n3**, así que no vería
> esta celda. Antes de usar otro Nord CE 2 Lite, revisar el número de modelo en *Ajustes → Acerca del
> dispositivo*.

Fuentes de las bandas (fichas de terceros):
[GSMArena](https://www.gsmarena.com/oneplus_nord_ce_2_lite_5g-11344.php),
[imei.org](https://imei.org/phone-model-lookup/oneplus-nord-ce-2-lite-5g_11673),
[myworldphone (CPH2409)](https://myworldphone.com/en-ca/products/op-ce2-lt-5g-cph2409-8-128-bk),
[Kimovil](https://www.kimovil.com/en/frequency-checker/IN/oneplus-nord-ce-2-lite-5g).

**Estado observado con la SIM insertada (antes de registrarse en la celda):**

- El celular lee la SIM: en *Operadores de redes* aparece **"No hay servicios – SISCOM2"**. `SISCOM2`
  es el SPN grabado en la SIM, así que la tarjeta se lee bien; "no hay servicios" solo significa que
  todavía no encontró la celda (gNB apagado, lejos o sin seleccionar la red).
- *Número de SIM*: "no definido". Es lo esperado: la SIM no tiene MSISDN y la red no lo usa.

### 4.1 Básica

1. Con el celular apagado, insertar la SIM (si es dual SIM, en la ranura 1 y sin otra SIM de datos).
2. *Ajustes → Red móvil → SIM → Tipo de red preferida*: **5G/4G/3G/2G (automático)**.
3. *Ajustes → Red móvil → SIM → Nombres de puntos de acceso (APN)* → **Nueva APN**. Campos tal como
   aparecen en OxygenOS 14:

   | Campo | Valor | Nota |
   |---|---|---|
   | Nombre | `SISCOM2` | Libre, solo para identificarla |
   | APN | `internet` | Debe ser igual al DNN de `smf.yaml` y del suscriptor (minúsculas) |
   | Proxy / Puerto | vacío | |
   | Nombre de usuario / Contraseña / Servidor | vacío | El core no autentica la APN |
   | MMSC / Proxy MMS / Puerto MMS | vacío | No hay MMS en el lab |
   | MCC / MNC | `001` / `01` | PLMN de la SIM y del AMF |
   | Tipo de autenticación | Ninguno | |
   | Tipo de APN | `default,supl` | Texto libre, con coma y **sin espacios**. Basta con `default`; no poner `ims` ni `mms` |
   | Protocolo APN | `IPv4` | El pool del SMF es solo IPv4 (`10.99.0.0/16`) |
   | Protocolo de roaming APN | `IPv4` | |
   | Tipo de conexión (bearer) | **No especificado** | Elegir `LTE` u otro la limitaría a esa tecnología |
   | Tipo MVNO | Ninguno | |

   Guardarla (menú ⋮ → *Guardar*) y **seleccionarla** en la lista.
4. *Ajustes → Red móvil → SIM → Operador de red*: desactivar selección automática, esperar la búsqueda y
   elegir **00101** / **SISCOM2** (puede aparecer como `001 01`).
5. Activar **datos móviles** con SIM1 como SIM de datos, e **itinerancia de datos** (venía desactivada; el
   firmware puede tratar el PLMN de pruebas como roaming y no abrir la sesión de datos).
6. **Llamadas VoLTE: desactivar** (venían activadas). El lab no tiene IMS; con VoLTE el celular reintenta
   registrarse en IMS y llena los logs. No impide los datos. **VoWiFi** se deja desactivado.
7. Si no aparece nada: modo avión 10 s y fuera, o reiniciar el celular.

Resumen de la configuración del OnePlus para esta celda:

| Ajuste | Valor |
|---|---|
| Tipo de red preferida | 5G/4G/3G/2G (Auto) (no elegir las opciones sin 5G) |
| APN | `SISCOM2` / `internet`, IPv4, `default,supl`, sin autenticación |
| Itinerancia de datos | Activada |
| VoLTE / VoWiFi | Desactivados |
| Operador | Manual: `00101` / SISCOM2 |
| Datos móviles | Activados en SIM1 |

### 4.2 Si no se engancha en 5G

- Menú de pruebas de Android: marcar `*#*#4636#*#*` → *Phone information* → *Set preferred network type*
  → **NR only** (o *NR/LTE*). En algunos OnePlus el menú no aparece o no tiene esta opción.
- Menú de ingeniería de OnePlus: `*#800#` (registros *Logkit*) y `*#899#`; varía según la versión de
  OxygenOS/ColorOS.
- Apps de observación sin root: *NetMonster* o *Network Cell Info Lite* muestran la banda, PCI, RSRP y
  SINR de la celda NR.

### 4.3 Comprobaciones desde el celular

- Ajustes → *Acerca del teléfono → Estado → Estado de la SIM*: red `SISCOM2` (o `SISCOM2 5G Lab`), tipo de
  red **NR**, y la dirección IP `10.99.x.y`.
- Navegar o hacer ping (app *Ping* / *PingTools*) a `10.88.4.10` (contenedor DN) y a `8.8.8.8`.

## 5. Logs útiles para ver qué está pasando

Arrancar con la verbosidad necesaria. Por defecto el gNB registra solo `warning`; para diagnosticar:

```bash
LOG_LEVEL=info scripts/gen-radio-configs.sh && ./usrp-start.sh
```

### 5.1 Core (Open5GS)

Seguir todos a la vez mientras el celular intenta conectarse:

```bash
docker compose logs -f --tail 0 amf ausf udm smf upf
```

Qué buscar en cada uno (los textos exactos pueden variar un poco):

| Contenedor | Línea esperada | Si falla |
|---|---|---|
| `amf` | `InitialUEMessage`, `Registration request`, `[suci-0-001-01-…]` | Nada: el celular no llega a la celda (banda, potencia, PLMN) |
| `amf` / `ausf` / `udm` | Autenticación correcta; puede aparecer un `Synch failure` / `re-sync` | `Authentication failure` / `MAC failure` repetido → **Ki u OPc mal escritos** en la SIM |
| `amf` | `[imsi-001010123456780] Registration complete` | `Security mode reject` → el celular no acepta NEA0 |
| `smf` | `UE IMSI[001010123456780] DNN[internet] IPv4[10.99.0.x]` | `DNN` o slice no coinciden → revisar el APN del celular |
| `upf` | Sesión creada, sin errores de GTP-U | Errores de túnel → revisar N3 en `br-5g-ran` |

El AMF también publica métricas en `http://10.88.1.2:9090/metrics` (nº de UEs registrados).
La WebUI (`http://127.0.0.1:3000`, `admin` / `1423`) permite ver y editar el suscriptor.

### 5.2 gNB (srsRAN con USRP)

```bash
make usrp-logs              # últimas líneas de la consola del gNB
docker attach gnb-usrp      # consola en vivo; pulsar  t  para métricas por UE (Ctrl-p Ctrl-q para salir)
tail -f logs/gnb.log        # log detallado (más útil con LOG_LEVEL=info)
```

- Con el celular conectado, la tabla de métricas (`t`) muestra una fila por UE con **CQI, MCS, BLER,
  bitrate DL/UL** y el RNTI. Si aparece una fila y desaparece, el celular hizo RACH pero falló después.
- En `logs/gnb.log` (nivel info): `RACH`, `RRC Setup`, `UE context`, `PDU Session Resource Setup`.
- `Late` / `Underflow` / `Overflow` frecuentes indican problemas de USB o CPU, no de la SIM.

### 5.3 Capturas para Wireshark

El gNB guarda capturas propias en `captures/` (configuradas en `gnb_usrp_*.yml`):

- `captures/gnb_ngap.pcap`: NGAP (N2) con el NAS dentro. Como el cifrado es NEA0, **se ven en claro**
  el Registration Request, la autenticación, el Security Mode y el PDU Session Establishment.
- `captures/gnb_mac.pcap`: capa MAC NR (disector `mac-nr`) con el RACH y el RRC.

Captura de las interfaces del core en los bridges (N2/N3, SBI/N4, N6):

```bash
docker compose --profile capture up -d tools
docker exec tools tcpdump -i br-5g-ran -nn -s 0 -w /captures/oneplus_ran.pcap   # N2 (NGAP) + N3 (GTP-U)
docker exec tools tcpdump -i br-5g-cn  -nn -s 0 -w /captures/oneplus_cn.pcap    # SBI (HTTP/2) + N4 (PFCP)
```

En Wireshark, filtros útiles: `ngap`, `nas-5gs`, `pfcp`, `gtp`, `http2`.

### 5.4 Del lado del celular (opcional)

Con depuración USB activada y `adb` en el PC:

```bash
adb logcat -b radio -v time
```

Muestra el registro en red, el estado de los datos, la IP asignada y los rechazos (*reject cause*) que
envía la red.

### 5.5 Diagnóstico rápido

| Síntoma | Causa probable | Dónde mirarlo |
|---|---|---|
| El celular no ve la red `00101` | Sin soporte de n3 SA, potencia baja o gNB caído | Ficha del modelo; `make usrp-logs`; HackRF (`make rf-check`) |
| Ve la red pero "Sin servicio" | Registro rechazado | `docker compose logs amf` (*reject cause*) |
| `MAC failure` en cada intento | Ki/OPc de la SIM ≠ `mongo-init.js` | Reprogramar la SIM con los valores de §1 |
| Registrado pero sin datos | APN ≠ `internet` o datos móviles desactivados | `docker compose logs smf`; APN en el celular |
| Datos a `10.88.4.10` pero no a Internet | Ruta de salida del DN | `docker exec dn ping 8.8.8.8` |
