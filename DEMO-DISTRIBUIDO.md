# Demo: red 5G repartida en dos equipos (Raspberry Pi 5 + PC)

Guía paso a paso para mostrar la red funcionando con el **core 5G y el gNB en la Raspberry Pi** y el
**UE en el PC**. Usamos los comandos de Docker a mano (sin `make`) para que se vea qué pasa en cada
paso. Cada bloque dice dónde se ejecuta:

- 🟦 **PC**: terminal normal del PC, dentro de la carpeta `5GDockerNetwork/`.
- 🟥 **Pi**: terminal de la Raspberry. Se abre desde el PC con `ssh pi-cable` y luego `cd ~/5GDockerNetwork`.

Conviene tener dos terminales abiertas lado a lado, una en cada equipo.

| Equipo | IP en el cable | Qué corre |
|---|---|---|
| PC (x86) | `10.42.0.1` | `ue` (srsUE) |
| Raspberry Pi 5 (ARM64) | `10.42.0.28` | `mongo`, `webui`, `nrf`, `amf`, `smf`, `upf`, `ausf`, `udm`, `udr`, `pcf`, `bsf`, `nssf`, `dn`, `gnb` |

Lo único que viaja por el cable entre los dos equipos es la "radio": las muestras IQ que gNB y UE se
mandan por ZeroMQ (puerto 2000 para la bajada, 2001 para la subida). El cable es de 100 Mbit/s y la
radio simulada pide unos 737, así que todo va más lento que en un solo PC (ping de ~250 ms en vez de
~29 ms). Funciona igual, solo más despacio.

---

## 0. Antes de empezar (solo la primera vez)

🟦 **PC**: comprobar que la Pi responde por el cable:

```bash
ping -c 3 10.42.0.28
ssh pi-cable hostname          # debe responder "raspberrypi"
```

🟦 **PC**: copiar el proyecto a la Pi (repetirlo si se cambia algo en el PC):

```bash
rsync -a --delete --exclude .git --exclude captures --exclude logs --exclude results \
  --exclude images/phy-sim ./ pi-cable:5GDockerNetwork/
```

🟥 **Pi**: compilar las imágenes para ARM64 (~1 h; si ya existen, este paso se salta):

```bash
docker images | grep -E 'siscom|mongo'     # si ya están las 4 de siscom + mongo, saltar lo de abajo
docker build -t siscom/open5gs:2.7.7 images/open5gs
docker build -t siscom/open5gs-webui:2.7.7 images/open5gs-webui
docker build -t siscom/dn:1.0 images/dn
docker build -t siscom/gnb:24.10.1 --build-arg JOBS=3 --build-arg MARCH=armv8.2-a+dotprod+fp16 images/gnb
docker pull mongo:6.0
```

🟦 **PC**: la imagen del UE ya existe si alguna vez se corrió la red local. Si no:

```bash
docker compose --profile ran build ue
```

---

## 1. Levantar el core 5G en la Pi

🟥 **Pi**: definir las IP y un atajo para no repetir el comando largo de Compose:

```bash
cd ~/5GDockerNetwork
export PI_IP=10.42.0.28 PC_IP=10.42.0.1
DC="docker compose --env-file .env --env-file split-pi.env -f docker-compose.yml -f docker-compose.split-pi.yml"
```

> Si se cierra la terminal de la Pi, hay que volver a correr estas tres líneas.

🟥 **Pi**: arrancar el core (13 contenedores):

```bash
$DC up -d
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Se espera ver los 13 contenedores `Up`, con `nrf` y `mongo` en `(healthy)`.

🟥 **Pi**: comprobar que el AMF escucha al gNB (N2) y que el SMF controla al UPF (N4):

```bash
docker logs amf 2>&1 | grep ngap_server        # -> ngap_server() [10.88.2.2]:38412
docker logs smf 2>&1 | grep 'PFCP associated'  # -> PFCP associated [10.88.1.3]:8805
```

🟦 **PC** (opcional): abrir la WebUI en el navegador: <http://10.42.0.28:3000> (`admin` / `1423`).
Ahí se ve el suscriptor `001010123456780`, que es la SIM simulada del UE. Si no deja entrar, crear el
usuario desde la Pi:

```bash
docker exec webui node -e "const m=require('mongoose');const A=require('./server/models/account');(async()=>{await m.connect(process.env.DB_URI);if(!(await A.countDocuments({username:'admin'}))){await A.register(new A({username:'admin',roles:['admin']}),'1423');}process.exit(0);})()"
```

---

## 2. Levantar el gNB en la Pi

🟥 **Pi**:

```bash
$DC --profile ran up -d gnb
```

🟥 **Pi**: esperar unos 30 s y comprobar que el gNB se conectó al AMF (NG Setup):

```bash
docker logs amf 2>&1 | grep 'gNB-N2 accepted'  # -> gNB-N2 accepted[10.88.2.20]
docker logs gnb 2>&1 | tail -3                 # -> N2: Connection to AMF ... completed / gNB started
```

En este punto la celda 5G ya está "al aire", esperando al UE en el puerto 2000 de la Pi.

---

## 3. Levantar el UE en el PC

🟦 **PC** (dentro de `5GDockerNetwork/`):

```bash
export PI_IP=10.42.0.28 PC_IP=10.42.0.1
docker compose -f docker-compose.yml -f docker-compose.split-pc.yml --profile ran up -d ue
```

🟦 **PC**: seguir el registro del UE en vivo (tarda unos 20-60 s). Salir con `Ctrl-C` cuando
aparezca la sesión PDU:

```bash
docker logs -f ue
```

Lo que se ve, en orden:

```
Attaching UE...
Random Access Complete.     c-rnti=0x4601, ta=0     <- el UE encontró la celda del gNB de la Pi
RRC Connected                                       <- conexión de radio establecida
PDU Session Establishment successful. IP: 10.99.0.2 <- el core le dio IP: ya tiene "datos móviles"
```

🟦 **PC**: mandar todo el tráfico del UE por el túnel 5G. La primera línea es para que la radio (ZMQ
hacia la Pi) **no** se meta en el túnel; la segunda pone el túnel como ruta por defecto:

```bash
docker exec ue ip route replace 10.42.0.28/32 via 10.88.3.1
docker exec ue ip route replace default dev tun_srsue
```

---

## 4. Pruebas para mostrar

### 4.1 El UE está en el PC y el resto en la Pi

🟦 **PC**:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'   # solo aparece "ue"
```

🟥 **Pi**:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'   # core + gnb, sin "ue"
```

### 4.2 La radio cruza el cable

🟦 **PC**: conexiones ZMQ del UE (una hacia la Pi, otra entrante desde la Pi):

```bash
docker exec ue ss -tn
# ESTAB ... 10.88.3.21:41076   10.42.0.28:2000   <- el UE lee la bajada del gNB en la Pi
# ESTAB ... 10.88.3.21:2001    ...               <- el gNB lee la subida del UE
```

🟥 **Pi**: lo mismo visto desde el gNB:

```bash
docker exec gnb ss -tn | grep 200
# ESTAB ... 10.88.3.20:39314   10.42.0.1:2001    <- el gNB se conecta al UE del PC
```

### 4.3 El core registró al UE y le dio IP

🟥 **Pi**:

```bash
docker logs amf 2>&1 | grep 'imsi-001010123456780' | tail -3     # registro en el AMF
docker logs smf 2>&1 | grep 'IPv4\['                              # SMF: IMSI, DNN internet, IPv4 10.99.0.2
```

🟦 **PC**: la IP aparece en la interfaz del UE:

```bash
docker exec ue ip -4 addr show tun_srsue      # inet 10.99.0.2/16
```

### 4.4 Tráfico de datos por la red 5G

🟦 **PC**: ping al servidor de pruebas que está detrás del UPF (en la Pi):

```bash
docker exec ue ping -c 5 10.88.4.10
```

🟦 **PC**: **Internet a través del 5G** (UE en el PC → gNB en la Pi → UPF en la Pi → Internet):

```bash
docker exec ue ping -c 5 8.8.8.8
docker exec ue ping -c 3 google.com
```

🟦 **PC**: velocidad (subida y bajada, 10 s cada una):

```bash
docker exec ue iperf3 -c 10.88.4.10 -t 10       # subida (UE -> red)
docker exec ue iperf3 -c 10.88.4.10 -t 10 -R    # bajada (red -> UE)
```

Medimos ~2.7 Mbit/s en cada sentido. Es poco porque la radio va ~8.6 veces más lenta que el tiempo
real por el cable de 100 Mbit/s; en un solo PC da ~26-30 Mbit/s.

🟥 **Pi**: los paquetes del UE pasaron por el UPF (contadores de la interfaz `ogstun`):

```bash
docker exec upf ip -s link show ogstun
```

### 4.5 Consola del gNB con métricas de radio

🟥 **Pi**:

```bash
docker attach gnb
```

Escribir `t` + Enter para ver cada segundo el MCS, CQI, BLER y throughput del UE. Para salir **sin
apagar el gNB**: `Ctrl-p` y luego `Ctrl-q` (no usar `Ctrl-C`, eso lo apaga).

Lo mismo para el UE desde el PC: 🟦 `docker attach ue`, `t`, y salir con `Ctrl-p Ctrl-q`.

---

## 5. Apagar

🟦 **PC**:

```bash
docker compose -f docker-compose.yml -f docker-compose.split-pc.yml --profile ran down
```

🟥 **Pi**:

```bash
$DC --profile ran down
```

La base de suscriptores queda guardada en la Pi para la próxima vez.

---

## Si algo falla

| Síntoma | Qué hacer |
|---|---|
| `docker logs amf` no muestra `gNB-N2 accepted` | Esperar hasta ~60 s; revisar `docker logs gnb 2>&1 \| tail` en la Pi |
| El UE se queda en `Attaching UE...` | Reiniciar los dos lados de la radio, primero el gNB y luego el UE: 🟦 `docker rm -f ue`, 🟥 `$DC --profile ran up -d --force-recreate gnb`, esperar el `gNB-N2 accepted` y volver al paso 3 |
| `ping 8.8.8.8` falla pero `ping 10.88.4.10` funciona | 🟥 `ping -c 3 8.8.8.8` en la Pi: la Pi sale a Internet a través del PC; revisar que el PC tenga Internet |
| `$DC: command not found` o `no configuration file provided` en la Pi | Volver a correr las tres líneas del paso 1 (`cd`, `export`, `DC=...`) |
| El UE se reinició solo o se cayó la radio | Siempre reiniciar los dos: gNB primero (paso 2), UE después (paso 3) |

Todo esto lo hace solo `make split-up && make split-verify` (ver `README.md`), que además corre 29
comprobaciones automáticas.
