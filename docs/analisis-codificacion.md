# Análisis de codificación de canal y elección de MCS

Este documento justifica con números qué codificación usa nuestra red (LDPC para datos, Polar para
control) y qué MCS (modulación y tasa de código) elige según el canal. Todo sale de un script
reproducible:

```bash
make bler       # simulación BLER vs SNR (LDPC y Polar) con la PHY de srsRAN 4G  (~3 min)
make measure    # mediciones en la red real: TBS del scheduler, barrido de MCS y de BW (~35 min)
make analysis   # tablas, gráficas y results/analysis/resumen.md
```

Los números de las tablas vienen de `results/analysis/*.csv` y las figuras de `results/analysis/*.png`.

## 1. La cadena de codificación de un bloque de datos

Cuando el gNB transmite datos de usuario en un slot (PDSCH), el bloque de transporte pasa por esta
cadena (TS 38.212 §7.2 y TS 38.211 §7.3.1):

```
bloque de transporte (TBS bits, decidido por MCS y nº de PRB)
 → CRC del TB (16 o 24 bits)  → selección del grafo base LDPC (BG1/BG2)
 → segmentación en code blocks (+CRC 24 por bloque)  → codificación LDPC
 → rate matching (buffer circular, versión de redundancia RV) → scrambling
 → modulación QPSK/16QAM/64QAM  → mapeo a REs (sin los REs de DMRS) → OFDM → IQ por ZMQ
```

El MCS fija dos cosas: el orden de modulación Qm (bits por símbolo) y la tasa de código R. Su producto
Qm·R es la **eficiencia espectral** en bits por elemento de recurso (RE). El canal decide cuánta
eficiencia se puede sostener.

## 2. Por qué LDPC para datos y Polar para control

3GPP eligió LDPC para los datos de eMBB en la reunión RAN1#86bis (octubre de 2016) y códigos Polar
para el control en RAN1#87 (noviembre de 2016). La razón está en el tamaño de los bloques:

| | Datos (PDSCH/PUSCH) | Control (PDCCH/DCI, PBCH, UCI > 11 bits) |
|---|---|---|
| Tamaño típico | miles a decenas de miles de bits (31 752 bits a MCS 28 en nuestra celda) | decenas de bits (DCI 1_0 = 39 bits, MIB = 32 bits) |
| Código | **LDPC** cuasi-cíclico, 2 grafos base | **Polar** con CRC (decodificación por lista) |
| Ventaja que importa | decodificación iterativa muy paralelizable (alto throughput); con bloques largos queda cerca de Shannon; soporta HARQ por redundancia incremental (RV 0-3) | muy buen desempeño con bloques cortos, donde LDPC pierde ganancia; rate matching flexible a cualquier E |

Nuestra simulación (sección 6) lo confirma. LDPC con bloques largos tiene una caída de BLER muy
abrupta: pasa de BLER 10 % a 1 % en unos 0.2 dB, y queda a 1.4-2 dB de Shannon en QPSK. Polar decodifica
una DCI de 63 bits con WER 1 % a −2.7 dB (AL4), algo que un código pensado para bloques largos no logra
con tan pocos bits. Para UCI muy cortas (≤ 11 bits, p. ej. el ACK de HARQ) se usan códigos de
repetición/simplex/Reed-Muller (TS 38.212 §5.3.3).

**Fuentes:** TS 38.212 §5.3 (Polar), §5.3.2 (LDPC), §5.3.3 (códigos para UCI cortas) —
https://www.3gpp.org/DynaReport/38212.htm · T. Richardson y S. Kudekar, "Design of Low-Density Parity
Check Codes for 5G New Radio", IEEE Communications Magazine 56(3), 2018 · V. Bioglio, C. Condo e I. Land,
"Design of Polar Codes in 5G New Radio", IEEE Communications Surveys & Tutorials 23(1), 2021
(arXiv:1804.04389).

## 3. LDPC: grafo base y segmentación, con nuestros números

**Regla de selección del grafo base** (TS 38.212 §7.2.2 para DL, §6.2.2 para UL). Con A = tamaño
del TB y R = tasa del MCS, se usa **BG2** si A ≤ 292, o si A ≤ 3824 y R ≤ 0.67, o si R ≤ 0.25. En
cualquier otro caso se usa **BG1**.

- BG1: 46×68 columnas base, Kb = 22 columnas de información, tasa madre 1/3, bloque máx. Kcb = 8448.
  Sirve para bloques grandes y tasas altas.
- BG2: 42×52, Kb ≤ 10, tasa madre 1/5, Kcb = 3840. Sirve para bloques pequeños o tasas bajas.

**Ejemplo 1: MCS 28 con 48 PRB.** Es lo que nuestra celda transmite a plena carga a 10 MHz, y el log
del scheduler lo confirma (`tbs=3969` bytes).

1. A = 31 752 bits, R = 948/1024 = 0.926. Como A > 3824 y R > 0.67, el grafo es **BG1**. El CRC del TB
   es de 24 bits, así que B = 31 776.
2. B > Kcb = 8448, así que hay que segmentar: C = ⌈B / (8448 − 24)⌉ = **4 code blocks**.
   Con B' = B + 24·C = 31 872, cada bloque lleva K' = 7968 bits.
3. El factor de expansión es el menor Zc con 22·Zc ≥ 7968, es decir Zc ≥ 362.2. El de la tabla
   5.3.2-1 es **Zc = 384**, con lo que K = 22·384 = 8448 (480 bits de relleno) y N = 66·384 = 25 344.
4. Bits disponibles: G = 5760 RE × 6 = 34 560. Cada bloque recibe E = G/C = 8640 bits, y la tasa
   efectiva queda en 7968/8640 = **0.922**, que coincide con R.

**Ejemplo 2: el RRC Setup.** El log del gNB muestra la asignación `rb=[0..42) tbs=309 mcs=3`.

1. A = 2472 bits y R = 251/1024 = 0.245 ≤ 0.25, así que el grafo es **BG2**.
2. B = 2472 + 16 = 2488 ≤ 3840, así que hay un solo bloque (C = 1). Como B > 640, Kb = 10.
3. Zc = 256, K = 2560 y N = 50·256 = 12 800 (tasa madre 1/5). E = 42·120·2 = 10 080 bits, lo que da
   una tasa de 0.247.

Los mensajes de control de RRC/NAS viajan con un MCS bajo y BG2: robustez antes que velocidad.

| MCS | Mod | R | TBS A | BG | C | K' | Zc | K | N | E/CB | tasa/CB |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | QPSK | 0.117 | 1352 | BG2 | 1 | 1368 | 144 | 1440 | 7200 | 11 520 | 0.119 |
| 3 | QPSK | 0.245 | 2856 | BG2 | 1 | 2872 | 288 | 2880 | 14 400 | 11 520 | 0.249 |
| 9 | QPSK | 0.663 | 7552 | BG1 | 1 | 7576 | 352 | 7744 | 23 232 | 11 520 | 0.658 |
| 17 | 64QAM | 0.428 | 14 856 | BG1 | 2 | 7464 | 352 | 7744 | 23 232 | 17 280 | 0.432 |
| 28 | 64QAM | 0.926 | 31 752 | BG1 | 4 | 7968 | 384 | 8448 | 25 344 | 8640 | 0.922 |

(48 PRB, 13 símbolos; tabla completa en `results/analysis/ldpc_segmentacion.csv`.)

## 4. Polar: tamaño del código y rate matching

El tamaño madre N = 2ⁿ se elige con las reglas de TS 38.212 §5.3.1:

- n1 = ⌈log₂E⌉, que baja en 1 si E es apenas mayor que una potencia de 2 y K/E < 9/16.
- n2 = ⌈log₂(8K)⌉, por la tasa mínima de 1/8.
- n = máx(mín(n1, n2, 9), 5). El valor 9 es el máximo en DL.

El rate matching (§5.4.1.1) depende de E y N:
- Si E ≥ N, se repiten bits.
- Si E < N y K/E ≤ 7/16, se perforan bits (puncturing).
- En otro caso se acorta el código (shortening).

| Caso | K (carga + CRC 24) | E | N | K/E | Rate matching | SNR para WER 1 % |
|---|---|---|---|---|---|---|
| PBCH (MIB) | 32 + 24 = 56 | 864 | 512 | 0.065 | repetición | −6.2 dB |
| DCI 1_0, AL 2 | 39 + 24 = 63 | 216 | 256 | 0.292 | puncturing | +0.7 dB |
| DCI 1_0, AL 4 | 63 | 432 | 512 | 0.146 | puncturing | −2.7 dB |
| DCI 1_0, AL 8 | 63 | 864 | 512 | 0.073 | repetición | −5.7 dB |

**Cómo se obtiene E.**
- PBCH: E = 864 bits fijos (TS 38.212 §7.1.5).
- PDCCH: E = 108·AL. Cada CCE tiene 6 REG; cada REG tiene 12 RE, de los que 3 son DMRS. Eso deja
  9 RE de datos por REG, y con QPSK (2 bits por RE) da 6 × 9 × 2 = 108 bits por CCE (TS 38.211
  §7.3.2).

**Cómo se obtienen los 39 bits de la DCI 1_0** (TS 38.212 §7.3.1.2.1, sumando campo a campo):

| Campo | Bits |
|---|---|
| Identificador | 1 |
| Asignación en frecuencia: ⌈log₂(48·49/2)⌉, con N = 48 RB de CORESET#0 | 11 |
| Asignación en tiempo | 4 |
| VRB-PRB | 1 |
| MCS | 5 |
| NDI | 1 |
| RV | 2 |
| Proceso HARQ | 4 |
| DAI | 2 |
| TPC | 2 |
| Recurso PUCCH | 3 |
| Retardo de HARQ | 3 |
| **Total** | **39** |

A 20 MHz, CORESET#0 tiene 96 RB y la DCI crece a 41 bits.

**Qué significa en nuestra red.** El nivel de agregación (AL) es el "MCS" del control: cada vez que se
dobla, se gana unos 3 dB. El scheduler del gNB usó AL 4 para el mensaje con TC-RNTI y AL 2 para el
C-RNTI ya conectado (`al=4` / `al=2` en el log). Con la SNR del enlace ZMQ (sección 6), el AL más bajo
basta de sobra.

## 5. Tablas MCS y cálculo del TBS

srsUE solo decodifica las DCI de respaldo 1_0/0_0 en el espacio de búsqueda común. Por eso TS 38.214
§5.1.3.1 y §6.1.4.1 obligan a usar la **tabla MCS 1 (hasta 64QAM)**, aunque se configurara
`mcs_table: qam256`. Los 29 MCS van de QPSK con R = 0.117 (SE 0.23 bit/RE) a 64QAM con R = 0.926
(SE 5.55). La tabla 2 (256QAM) llegaría a 7.4 bit/RE, +33 % (figura `fig1_mcs_eficiencia.png`).

**Fórmula del TBS** (TS 38.214 §5.1.3.2), con el ejemplo de MCS 28 y 48 PRB:

| Paso | Fórmula | Valor |
|---|---|---|
| RE útiles por PRB | N'_RE = 12·N_símb − N_DMRS − N_oh = 12·13 − 36 − 0 | 120 |
| RE asignados | N_RE = mín(156, N'_RE)·n_PRB = 120·48 | 5760 |
| Bits de información | N_info = N_RE·R·Qm·v = 5760·0.9258·6·1 | 31 995 |
| Cuantización | n = ⌊log₂(N_info − 24)⌋ − 5 = 9 ; N'_info = 2⁹·round(31 971/2⁹) | 31 744 |
| Segmentación | R > 1/4 y N'_info > 8424 → C = ⌈(N'_info + 24)/8424⌉ | 4 |
| TBS | 8C·⌈(N'_info + 24)/8C⌉ − 24 | **31 752 bits = 3969 B** |

**Validación contra la red real.** `scripts/measure.sh tbs` arranca el gNB con el log del scheduler en
`debug` y fija el MCS. Luego compara cada asignación distinta (PRB, símbolos, MCS, TBS) con nuestra
función `tbs_bits()`. El resultado está en `results/analysis/validacion_tbs.csv` y en la sección 3 de
`resumen.md`.

A 10, 15 y 20 MHz y con MCS 3, 9 y 28, **213 de 213 asignaciones distintas coinciden byte a byte**.
Por ejemplo: 48 PRB a MCS 28 dan 3969 B, 96 PRB dan 7941 B y 100 PRB de PUSCH dan 9222 B.

Hay otras 20 asignaciones PUSCH pequeñas (1-5 PRB) cuyo TBS corresponde a MCS 27 aunque el MCS esté
fijado en 28. La razón está en el código del scheduler (`mcs_tbs_calculator.cpp`): baja el MCS mientras
la tasa de código efectiva supere 0.95, que es el límite por encima del cual el UE puede no decodificar
(TS 38.214 §5.1.3.1). En bloques pequeños, el CRC y la cuantización del TBS empujan la tasa por encima
de ese límite. Como el log de PUSCH no imprime el MCS, estas 20 asignaciones se infieren, no se
validan.

Las coincidencias validan los supuestos del modelo: PDSCH en los símbolos 1-13, porque CORESET#0 ocupa el símbolo 0, y
DMRS tipo A en pos2 con 2 posiciones adicionales, es decir 3 símbolos × 12 RE (TS 38.211 §7.4.1.1.2).

**Fuentes:** TS 38.214 §5.1.3.1 (tablas MCS), §5.1.3.2 (TBS), §5.2.2.1 (tablas CQI), §6.1.4.1 (MCS de
PUSCH) — https://www.3gpp.org/DynaReport/38214.htm · TS 38.211 §7.3.2 y §7.4.1.1.2 —
https://www.3gpp.org/DynaReport/38211.htm · TS 38.213 §13, tabla 13-1 (CORESET#0) —
https://www.3gpp.org/DynaReport/38213.htm

## 6. El canal decide el MCS: BLER vs SNR y límite de Shannon

### 6.1 Por qué hace falta simular el canal aparte

En ZMQ las muestras IQ viajan por TCP sin ruido. El gNB mide una SNR de PUSCH de unos **65 dB**
(columna `pusch` de la consola). Con esa SNR, cualquier MCS se decodifica. El emulador de canal de
srsUE (`[channel.dl.awgn]`) solo está conectado en la ruta LTE: lo comprobamos en el código de la
versión fijada (`srsue/src/phy/sync.cc` lo invoca; `sync_sa.cc`, la ruta 5G SA, no). Por eso **no se
puede añadir ruido a la red ZMQ**, y el efecto del canal se estudia con una simulación de enlace
aparte.

La imagen `siscom/phy-sim:25.10` compila dos pruebas de la misma biblioteca PHY de srsRAN 4G que usa
srsUE:
- `pusch_nr_bler_test`: cadena NR completa, con LDPC, rate matching, QAM, la misma DMRS que nuestra
  celda y AWGN. Se corre con 48 PRB × 14 símbolos para los 29 MCS, de −8 a 32 dB en pasos de 0.5 dB,
  hasta 100 errores o 2000 bloques por punto.
- `polar_chain_test`: Polar con los K/E de la sección 4.

En las dos, SNR significa Es/N0 por RE y la estimación de canal es perfecta: es un límite optimista
de la realidad.

### 6.2 Resultados

| MCS | Mod | SE (bit/RE) | SNR mín. Shannon | SNR para BLER 10 % | Brecha |
|---|---|---|---|---|---|
| 0 | QPSK | 0.23 | −7.5 dB | −5.5 dB | 2.0 dB |
| 4 | QPSK | 0.60 | −2.9 dB | −1.3 dB | 1.5 dB |
| 9 | QPSK | 1.33 | 1.8 dB | 3.7 dB | 1.9 dB |
| 10 | 16QAM | 1.33 | 1.8 dB | 5.2 dB | 3.4 dB |
| 15 | 16QAM | 2.41 | 6.3 dB | 8.6 dB | 2.3 dB |
| 17 | 64QAM | 2.57 | 6.9 dB | 10.1 dB | 3.2 dB |
| 22 | 64QAM | 3.90 | 11.5 dB | 14.1 dB | 2.6 dB |
| 26 | 64QAM | 5.12 | 15.3 dB | 19.1 dB | 3.8 dB |
| 28 | 64QAM | 5.55 | 16.6 dB | 21.2 dB | 4.5 dB |

(Los 29 MCS están en `bler_umbral_snr.csv`; ver `fig2_bler_ldpc.png` y `fig3_shannon_adaptacion.png`.)

La SNR mínima de Shannon sale de C = log₂(1 + SNR): para sostener SE bits/RE hace falta
SNR ≥ 2^SE − 1 (C. E. Shannon, "A Mathematical Theory of Communication", 1948).

### 6.3 Lectura crítica

1. **LDPC trabaja cerca de la capacidad.** A tasas bajas y medias la brecha es de 1.4 a 2 dB con QPSK
   y de 2.3 a 3.4 dB con 16QAM. Esto es con 1 transmisión y bloques de 1 a 4 code blocks. Las curvas
   son casi verticales, de BLER 10 % a 1 % en ~0.2 dB, típico de LDPC con bloques largos. Por eso un
   MCS que funciona lo hace con BLER ≈ 0 y uno que falla lo hace casi siempre.
2. **La brecha crece en los MCS altos (4.5-4.8 dB a MCS 27-28).** Hay dos causas. Primera, con R ≈ 0.9
   el código tiene muy poca redundancia. Segunda, 64QAM no puede pasar de 6 bit/RE, y SE = 5.55 es el
   92 % de ese techo: la curva de capacidad de una constelación fija se aplana antes que la de Shannon
   con entrada gaussiana.
3. **Los MCS que se solapan no valen lo mismo.** MCS 9 (QPSK, R 0.66) y MCS 10 (16QAM, R 0.33) tienen
   la misma eficiencia, 1.33 bit/RE. Aun así, MCS 9 necesita **1.5 dB menos**. Lo mismo pasa con
   MCS 16 (16QAM) frente a MCS 17 (64QAM): 0.56 dB a favor de la modulación más baja. La curva de
   adaptación de enlace (línea azul de la fig. 3) usa la modulación más baja en esos puntos de cruce.
4. **Selección por CQI.** El UE mide el CSI-RS y reporta un CQI de la tabla 1 (TS 38.214 tabla
   5.2.2.1-2). Cada CQI equivale a un MCS con el mismo (Qm, R): CQI 15 corresponde a MCS 28 (21.2 dB),
   CQI 12 a MCS 22 (14.1 dB) y CQI 7 a MCS 11 (5.6 dB) (`cqi_snr.csv`). Encima, el gNB aplica OLLA
   (outer-loop link adaptation): corrige el CQI según los ACK/NACK de HARQ para apuntar a un BLER
   objetivo. En srsRAN 24.10 ese objetivo es del 1 % (`olla_target_bler = 0.01` en
   `du_high_config.h`).

### 6.4 Justificación del MCS de nuestra red

- **Canal ZMQ.** El gNB mide 65 dB de SNR en el PUSCH y el UE reporta **CQI 15**. Hay 44 dB de margen
  sobre los 21.2 dB que necesita MCS 28, así que el scheduler usa **MCS 28 (64QAM, R 0.926)** en ambos
  sentidos, con 0 % de NACK (consola del gNB, `docs/rendimiento.md`). Es la elección correcta: con
  BLER ≈ 0, el throughput es máximo con el MCS más alto de la tabla.
- **Fase 2, con SDR y cable o atenuadores.** La SNR real dependerá de la ganancia y de la atenuación.
  Con la tabla anterior: a 15 dB se esperaría un MCS en torno a 22-23 (SE ≈ 4 bit/RE, ~72 % del pico
  de MCS 28); a 8 dB, alrededor de MCS 13-14 con 16QAM; y por debajo de 4 dB, solo QPSK. El OLLA
  ajustará esto solo, y los umbrales sirven para predecir el throughput que se verá en esa fase.
- **256QAM.** El margen de 44 dB alcanzaría para 256QAM (SE 7.4 necesita ≥ 22.3 dB de Shannon más
  una brecha de ~4-5 dB). No se usa por la limitación de DCI de srsUE (sección 5), no por el canal.

## 7. Velocidad teórica de nuestra celda

**Fórmula de pico, TS 38.306 §4.1.2:**

Tasa = 10⁻⁶ · v · Qm · f · Rmax · (N_PRB·12 / Tsμ) · (1 − OH)

con v = 1 capa, Qm = 6, f = 1, Rmax = 948/1024, Tsμ = 10⁻³/14 s (μ = 0) y OH = 0.14 en DL / 0.08 en UL.

| BW | N_PRB | Pico 38.306 DL | PRB DL usables | TBS MCS 28 × 1000 slots/s (DL) | PRB UL | ídem UL |
|---|---|---|---|---|---|---|
| 10 MHz | 52 | 41.7 Mbit/s | 48 | 31.8 Mbit/s | 46 | 33.8 Mbit/s |
| 15 MHz | 79 | 63.4 Mbit/s | 48 | 31.8 Mbit/s | 73 | 53.3 Mbit/s |
| 20 MHz | 106 | 85.1 Mbit/s | 96 | 63.5 Mbit/s | 100 | 73.8 Mbit/s |

**Por qué el techo real queda por debajo de la fórmula:**

1. **El DL está limitado por CORESET#0.** Con DCI 1_0 en el espacio de búsqueda común, el campo de
   asignación en frecuencia se dimensiona con el tamaño de CORESET#0 (TS 38.212 §7.3.1.2.1). Son
   48 RB a 10 y 15 MHz (índice 6) y 96 RB a 20 MHz (índice 12; TS 38.213 tabla 13-1).
   **Consecuencia que se puede verificar: a 15 MHz el DL no debería mejorar respecto a 10 MHz**
   (sección de barrido de BW en `docs/rendimiento.md`).
2. **El UL pierde los PRB de PUCCH.** A 10 MHz el log muestra `rb=[3..49)`, es decir 46 de 52 PRB.
3. **Overhead fijo.** Un símbolo de PDCCH, 3 símbolos de DMRS por slot y slots sin PDSCH de usuario
   (SSB, SIB1, CSI-RS).
4. **Más arriba de la PHY**, las cabeceras MAC/RLC/PDCP/SDAP, GTP-U/UDP/IP en N3 y TCP restan otro
   10-15 %.

La comparación medida contra teórica, con el barrido de MCS y de ancho de banda, está en
`docs/rendimiento.md`.

**Fuentes:** TS 38.306 §4.1.2 — https://www.3gpp.org/DynaReport/38306.htm · TS 38.212 §7.3.1.2.1 ·
TS 38.213 tabla 13-1 · código de srsRAN Project `release_24_10_1`
(`apps/units/flexible_du/du_high/du_high_config.h`) y srsRAN 4G `release_25_10`
(`lib/src/phy/phch/test/pusch_nr_bler_test.c`, `lib/src/phy/fec/polar/test/polar_chain_test.c`).
