// =====================================================================================================
// Siembra de la base de datos de Open5GS (lo que en una operadora real sería el "HSS/UDR"):
// MongoDB ejecuta este script UNA sola vez, cuando el volumen 5g-mongo-data se crea vacío.
// Para que se vuelva a ejecutar: `make clean` (borra el volumen) y `make up`.
//
// IMPORTANTE: los campos numéricos deben ser NumberInt/NumberLong. Si se escriben como números JS
// normales se guardan como "double" y el UDR de Open5GS falla (sqn -> 5G-AKA da HTTP 500;
// sst/ambr -> "No SST" / "No UE-AMBR"). Lección aprendida del repo previo.
// Estructura de referencia: open5gs/webui/server/models/subscriber.js
// =====================================================================================================
db = db.getSiblingDB('open5gs');   // base de datos que usan UDR, PCF y la WebUI

// La cuenta admin de la WebUI la crea scripts/up.sh con la función Account.register de la propia
// WebUI (passport-local-mongoose), porque con NODE_ENV=production la WebUI no la crea sola.

// Suscriptor de prueba (claves públicas de los tutoriales de srsRAN: SOLO para simulación).
db.subscribers.deleteMany({ imsi: '001010123456780' });  // idempotente: borra si ya existía
db.subscribers.insertOne({
  imsi: '001010123456780',        // IMSI = MCC 001 + MNC 01 + MSIN 0123456780 (15 dígitos). Es el SUPI del UE
  msisdn: [],                     // número de teléfono (no se usa: no hay voz)
  imeisv: [],                     // IMEI del equipo (vacío = cualquier equipo)
  mme_host: [],                   // campos de 4G (MME); vacíos en 5G SA
  mme_realm: [],
  purge_flag: [],
  subscribed_rau_tau_timer: NumberInt(12),   // temporizador periódico de área en minutos (campo de 4G); defecto WebUI
  network_access_mode: NumberInt(0),         // 0 = acceso a paquetes y circuitos (por defecto)
  subscriber_status: NumberInt(0),           // 0 = SERVICE_GRANTED (suscriptor activo)
  operator_determined_barring: NumberInt(0), // 0 = sin bloqueos impuestos por el operador
  access_restriction_data: NumberInt(32),    // bit 5 (=32): handover a acceso no-3GPP no permitido (TS 29.272); defecto WebUI
  slice: [                                   // slices (S-NSSAI) a los que puede entrar el UE
    {
      sst: NumberInt(1),                     // SST 1 = eMBB; debe coincidir con AMF, NSSF y gNB
      default_indicator: true,               // slice por defecto si el UE no pide uno concreto
      session: [                             // sesiones PDU permitidas en este slice
        {
          name: 'internet',                  // DNN: debe coincidir con smf.yaml/upf.yaml y [nas] apn del UE
          type: NumberInt(1),                // tipo de sesión: 1 = IPv4 (2 = IPv6, 3 = IPv4v6)
          pcc_rule: [],                      // reglas PCC adicionales del PCF (ninguna)
          ambr: {                            // Session-AMBR: velocidad máxima agregada de ESTA sesión
            uplink: { value: NumberInt(1), unit: NumberInt(3) },   // 1 Gbps (unit 3 = Gbps; 2 = Mbps)
            downlink: { value: NumberInt(1), unit: NumberInt(3) },
          },
          qos: {
            index: NumberInt(9),             // 5QI 9 = best effort sin garantía (TS 23.501 tabla 5.7.4-1)
            arp: {                           // ARP = prioridad de asignación/retención (1 = máx, 15 = mín)
              priority_level: NumberInt(8),
              pre_emption_capability: NumberInt(1),     // 1 = NO puede quitar recursos a otros
              pre_emption_vulnerability: NumberInt(1),  // 1 = NO se le pueden quitar recursos
            },
          },
        },
      ],
    },
  ],
  ambr: {                                    // UE-AMBR: velocidad máxima sumando todas las sesiones del UE
    uplink: { value: NumberInt(1), unit: NumberInt(3) },     // 1 Gbps
    downlink: { value: NumberInt(1), unit: NumberInt(3) },
  },
  security: {                                // credenciales para 5G-AKA (deben ser IGUALES a [usim] del UE)
    k: '00112233445566778899AABBCCDDEEFF',   // K (Ki): clave secreta de 128 bits compartida SIM <-> red
    amf: '8000',                             // "Authentication Management Field" de Milenage (no es la NF AMF)
    op: null,                                // usamos OPc en vez de OP
    opc: '63BFA50EE6523365FF14C1F45F88737D', // OPc: constante del operador ya combinada con K (Milenage)
    sqn: NumberLong(0),                      // SQN: contador anti-repetición; la red lo incrementa en cada autenticación
  },
  schema_version: NumberInt(1),              // versión del esquema que espera la WebUI de Open5GS
  __v: NumberInt(0),                         // campo interno de mongoose (WebUI)
});

print('open5gs db seeded: subscriber 001010123456780');
