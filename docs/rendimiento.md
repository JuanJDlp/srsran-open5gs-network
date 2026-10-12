# Rendimiento y latencia de la simulación ZMQ: medidas y análisis

Medidas tomadas el 2026-10-12 en un Ryzen 7 5825U (16 hilos, gobernador `powersave`), con la red de
este repositorio. Para reproducirlas: `make measure` y luego `make analysis`. Los datos crudos están
en `results/raw/` y las tablas en `results/analysis/` (`resumen.md`, `*.csv`, `fig5`-`fig7`). La
teoría que se usa para comparar (TBS, TS 38.306, BLER vs SNR) está en `docs/analisis-codificacion.md`.

## 1. Metodología

| Prueba | Cómo | Repeticiones |
|---|---|---|
| Latencia | `ping` UE→DN y DN→UE en reposo; UE→DN durante un TCP DL; DN→UPF (solo la parte cableada) | 100 / 50 / 32 / 50 muestras, intervalo 0.2 s |
| Throughput TCP | `iperf3` desde el UE (`tun_srsue`) hacia la DN, DL (`-R`) y UL, 10 s | 3 por sentido y por BW |
| UDP | tasa fija de 10 Mbit/s (jitter y pérdida) y saturado a 80 Mbit/s (capacidad) | 1 por sentido y por BW |
| Capa MAC | tabla de métricas del gNB (`autostart_stdout_metrics`), una fila por segundo: CQI, MCS, bit rate, ACK/NACK de HARQ, SNR de PUSCH | todos los segundos con carga |
| CPU/RAM | `docker stats` durante reposo, TCP DL, UDP UL y UDP DL saturado | ~5 muestras por fase |
| Barridos | BW 10/15/20 MHz con MCS adaptativo; MCS fijo 0/4/9/14/19/24/28 a 10 MHz | gNB y UE se reinician en cada corrida |

Cada corrida arranca de cero con `scripts/up.sh` y un archivo de overrides del gNB propio, así que las
corridas no se contaminan entre sí.

## 2. Resultados

### 2.1 Throughput vs ancho de banda (MCS adaptativo; en todos los casos CQI 15, MCS 28/28, 0 % de NACK)

| BW | Pico TS 38.306 DL | TBS DL ×1000 | MAC DL | UDP sat. DL (MAC) | TCP DL | TBS UL ×1000 | MAC UL | UDP sat. UL (MAC) | TCP UL |
|---|---|---|---|---|---|---|---|---|---|
| 10 MHz | 41.7 | 31.8 | 28.1 | 28.8 | **26.4 ± 0.06** | 33.8 | 33.2 | 32.8 | **30.1 ± 0.26** |
| 15 MHz | 63.4 | 31.8 | 29.1 | 30.0 | **26.7 ± 0.16** | 53.3 | 52.2 | 53.0 | **43.4 ± 1.1** |
| 20 MHz | 85.1 | 63.5 | 58.3 | 59.0 | **45.1 ± 0.38** | 73.8 | 72.4 | 70.6 | **46.5 ± 1.6** |

Unidades: Mbit/s. TCP = media ± desviación de 3 repeticiones. SNR de PUSCH medida por el gNB:
65.2-65.5 dB. Figura: `fig6_barrido_bw.png`.

### 2.2 Throughput vs MCS fijo (10 MHz)

| MCS | 0 | 4 | 9 | 14 | 19 | 24 | 28 |
|---|---|---|---|---|---|---|---|
| DL teórico (TBS×1000) | 1.35 | 3.50 | 7.55 | 12.55 | 17.42 | 26.12 | 31.75 |
| DL MAC | 1.20 | 3.08 | 6.83 | 11.00 | 15.82 | 24.00 | 28.60 |
| DL TCP | 1.12 | 2.87 | 6.31 | 10.40 | 14.38 | 20.91 | 26.54 |
| UL teórico | 1.42 | 3.75 | 8.06 | 13.06 | 18.43 | 27.66 | 33.82 |
| UL MAC | 1.40 | 3.62 | 8.00 | 13.00 | 18.00 | 27.00 | 34.00 |
| UL TCP | 1.06 | 3.15 | 7.24 | 11.71 | 16.45 | 24.96 | 30.32 |

0 % de NACK en todos los MCS. Figura: `fig5_barrido_mcs.png`.

### 2.3 Latencia (RTT, ms)

| Prueba (igual en 10/15/20 MHz, ±1 ms) | n | mín | media | p95 | máx | desv. |
|---|---|---|---|---|---|---|
| UE → DN, reposo | 100 | 18.9 | 29.0-29.9 | 38.1-38.9 | 39-40 | 6.0 |
| DN → UE, reposo | 50 | 19.7 | 30.0-30.7 | 39.5-39.9 | 40-41 | 6.2 |
| UE → DN durante TCP DL | 32 | 18-23 | 179-183 | 317-322 | 332-340 | 95 |
| DN → UPF (solo la red cableada) | 50 | 0.0 | 0.1 | 0.1 | 0.1 | 0.0 |

Con UDP a 10 Mbit/s no hubo pérdidas. El jitter fue de 0.5-0.6 ms en DL y de 1.7-2.0 ms en UL.
Figura: `fig7_latencia.png`.

### 2.4 Recursos (`docker stats`, % de un núcleo)

| | gNB | UE | UPF | AMF/SMF |
|---|---|---|---|---|
| Reposo | 165-183 % | 45-69 % | 0 % | 0 % |
| TCP DL / UDP DL saturado | 220-253 % | 142-234 % | 12-19 % | 0 % |
| Memoria | 2.3 GiB | 0.3 GiB | 20 MiB | 35-420 MiB |

## 3. Análisis crítico

**1. La PHY rinde lo que predice la teoría.**
- Los TBS calculados con TS 38.214 coinciden byte a byte con los del scheduler (`analisis-codificacion.md`
  §5).
- En UL, la tasa MAC queda en el 96-100 % de TBS×1000 en todos los MCS. El gNB programa un PUSCH en
  casi cada slot (994/s).
- En DL queda en el 88-92 %. La diferencia está en los slots: el gNB programa 965-990 PDSCH/s y
  algunos son pequeños (mensajes de control, MAC CE).
- No hay retransmisiones HARQ (0 % de NACK), coherente con un canal de 65 dB.

**2. El pico de TS 38.306 no se alcanza, y no es un error de configuración.** A 10 MHz la fórmula da
41.7 Mbit/s y medimos 28-29 en MAC. La diferencia tiene tres causas:
- El PDSCH queda limitado a los 48 RB de CORESET#0. Es efecto de la DCI 1_0, que es la única que
  srsUE soporta.
- El overhead real (1 símbolo de PDCCH y 3 de DMRS de 14) es mayor que el 14 % que supone la
  fórmula.
- Hay slots sin datos de usuario.

**La prueba más clara es la de 15 MHz.** El UL sube de 33 a 52 Mbit/s, como predicen los 73 PRB. El DL,
en cambio, se queda en ~29 Mbit/s, igual que a 10 MHz, como se había predicho antes de medir. A
20 MHz, CORESET#0 crece a 96 RB y el DL se duplica (58 Mbit/s).

**3. TCP pierde un 6-9 % más cuando la tasa es baja, y bastante más cuando pasa de ~45 Mbit/s.**
- A 10 MHz (en DL y UL) y en el DL de 15 MHz, TCP llega al 91-94 % de la tasa MAC. Lo que falta son
  las cabeceras: IP/TCP, más GTP-U/UDP/IP en N3 (que no consumen radio) y SDAP/PDCP/RLC/MAC (que sí).
- Cuando la radio da más, TCP no la aprovecha:
  - UL a 15 MHz: 43 de 52 Mbit/s (83 %).
  - DL a 20 MHz: 45 de 58 Mbit/s (77 %).
  - UL a 20 MHz: 46 de 72 Mbit/s (64 %).
- TCP parece estancarse en ~45 Mbit/s. La UDP saturada sí alcanza la capacidad de MAC, así que la
  radio no es el cuello de botella.
- **Hipótesis (no verificada):** el límite está en el UE. srsUE llega a 234 % de CPU con 4 núcleos
  asignados (`UE_CPUS=10-13`) y con el gobernador en `powersave`. A eso se suma el control de
  congestión de TCP con una RTT bajo carga de ~180 ms.
- La mayor desviación en UL (±1.1-1.6 Mbit/s) apunta en la misma dirección, hacia la CPU.

**4. La latencia viene de la RAN simulada, no del core.**
- La parte cableada (DN↔UPF) aporta 0.1 ms. Los ~29 ms de RTT son la radio simulada.
- El RTT no depende del ancho de banda. Tampoco del sentido: UE→DN y DN→UE miden lo mismo, lo que
  descarta que domine la espera del Scheduling Request en UL.
- Las muestras se reparten de forma casi uniforme entre 19 y 40 ms. Eso apunta a un componente
  periódico, por ejemplo el procesamiento por bloques de slots que gNB y UE adelantan sobre el reloj
  de muestras de ZMQ. Esta explicación es una hipótesis.
- En 5G real con μ = 0, el ciclo de HARQ (k1 = 4 slots = 4 ms) y la programación darían un RTT de
  ~10 ms. La simulación añade ~20 ms, que no deben atribuirse a 5G.

**5. Bajo carga, la latencia sube a ~180 ms por la cola del gNB (bufferbloat).**
- TCP llena la cola de RLC del gNB. La columna `dl_bs` de la consola mostró hasta 6 MB pendientes
  con UDP saturado.
- Un ping comparte esa cola: 180 ms de media con p95 de 320 ms, frente a 29 ms en reposo.
- Esto es una propiedad del diseño de colas, no de la radio. En una red real se mitiga con QoS por
  flujo (5QI distintos, AQM).

**6. Factibilidad y recursos.**
- El core completo consume casi nada: las NFs están en 0 %, el UPF llega al 19 % con 59 Mbit/s y
  MongoDB al ~30 %.
- El coste está en la RAN. El gNB ocupa 1.7 núcleos en reposo (el ZMQ hace busy-wait) y 2.5 bajo
  carga, más 2.3 GiB de RAM. El UE llega a 2.3 núcleos.
- Para la Fase 2 con SDR real (USRP B210 o similar) hace falta:
  - Un PC con ≥ 4 núcleos libres para el gNB y gobernador `performance`. Con radio real el tiempo
    es estricto: un retraso produce *underflows*, no solo latencia.
  - USB 3.0.
- Para el UE, la SNR real decidirá el MCS: la tabla de `analisis-codificacion.md` §6.4 permite
  predecir el throughput.

## 4. Limitaciones

- Un solo UE. No hay barrido de número de UEs: srsUE por ZMQ admite un UE por instancia de gNB sin
  un broker de ZMQ.
- No hay ruido en el enlace ZMQ: el emulador AWGN de srsUE no actúa en 5G SA. El efecto del canal se
  estudió aparte con la simulación BLER.
- Las mediciones de UDP saturado se toman de la tasa MAC del gNB. La tasa "recibida" de iperf3 se
  inflaba porque el gNB entregaba después de la ventana de 10 s lo que tenía en cola.
- Todo corre en un portátil con `powersave`, así que hay variabilidad de CPU entre corridas
  (desviación TCP < 4 %).
