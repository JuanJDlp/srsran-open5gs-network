// Seeds the Open5GS database on first start of the mongo volume.
// All numeric fields MUST be NumberInt/NumberLong: plain JS numbers are stored as double and
// Open5GS UDR then fails (sqn -> 5G-AKA HTTP 500, sst/ambr -> "No SST"/"No UE-AMBR").
db = db.getSiblingDB('open5gs');

// The WebUI admin account is created by scripts/up.sh through the WebUI's own Account.register
// (passport-local-mongoose), because NODE_ENV=production does not bootstrap it.

// Test subscriber (public lab keys from the srsRAN tutorials; simulation only).
db.subscribers.deleteMany({ imsi: '001010123456780' });
db.subscribers.insertOne({
  imsi: '001010123456780',
  msisdn: [],
  imeisv: [],
  mme_host: [],
  mme_realm: [],
  purge_flag: [],
  subscribed_rau_tau_timer: NumberInt(12),
  network_access_mode: NumberInt(0),
  subscriber_status: NumberInt(0),
  operator_determined_barring: NumberInt(0),
  access_restriction_data: NumberInt(32),
  slice: [
    {
      sst: NumberInt(1),
      default_indicator: true,
      session: [
        {
          name: 'internet',
          type: NumberInt(1), // IPv4
          pcc_rule: [],
          ambr: {
            uplink: { value: NumberInt(1), unit: NumberInt(3) },   // 1 Gbps
            downlink: { value: NumberInt(1), unit: NumberInt(3) },
          },
          qos: {
            index: NumberInt(9),
            arp: {
              priority_level: NumberInt(8),
              pre_emption_capability: NumberInt(1),
              pre_emption_vulnerability: NumberInt(1),
            },
          },
        },
      ],
    },
  ],
  ambr: {
    uplink: { value: NumberInt(1), unit: NumberInt(3) },
    downlink: { value: NumberInt(1), unit: NumberInt(3) },
  },
  security: {
    k: '00112233445566778899AABBCCDDEEFF',
    amf: '8000',
    op: null,
    opc: '63BFA50EE6523365FF14C1F45F88737D',
    sqn: NumberLong(0),
  },
  schema_version: NumberInt(1),
  __v: NumberInt(0),
});

print('open5gs db seeded: subscriber 001010123456780');
