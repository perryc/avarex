# BLE ADS-B Receiver Service

GATT service definition for streaming ADS-B/FANET traffic from a receiver
(ADSBee 1090U, future tri-band devices) to an EFB over Bluetooth Low
Energy. Designed for AvareX but intentionally EFB-agnostic.

## Why BLE, why this shape

- A traffic-only GDL90 stream (Canada has no FIS-B uplink) is a few kB/s —
  comfortably within BLE bandwidth. Wi-Fi stays free for a phone hotspot.
- BLE works on iOS/iPadOS, which Bluetooth SPP never did.
- This is a proper GATT design, not a serial pipe: characteristics are
  typed by content and every notification is one complete message. There is
  no byte-stream framing, no flag hunting, no partial-message reassembly.
- Payloads are standard framed GDL90 messages, so any existing EFB decoder
  understands them unchanged. The receiver performs all band fusion
  (1090ES, FANET, 978 if ever fitted) and emits one merged traffic picture.

## Service

Service UUID: `0BEE0001-1090-46F0-A9AC-52D6BE4C29CC`
(base `0BEExxxx-1090-46F0-A9AC-52D6BE4C29CC`; "0BEE 1090" = ADSBee 1090)

The service UUID MUST be included in advertising data so clients can scan
by service. Advertised name suggestion: `ADSBee-XXXX` (serial suffix).

### Characteristics

| UUID (`0BEExxxx-...`) | Name | Properties | Payload |
|---|---|---|---|
| `0BEE0010` | Traffic | notify | One framed GDL90 Traffic Report (ID 0x14) per notification |
| `0BEE0011` | Ownship | notify | One framed GDL90 Ownship Report (0x0A) or Ownship Geometric Altitude (0x0B) per notification |
| `0BEE0012` | Status | notify | One framed GDL90 Heartbeat (0x00) per notification, 1 Hz; MAY also carry vendor status messages (see below) |
| `0BEE0013` | Uplink | notify | Fragments of framed GDL90 Uplink Data (0x07) - FIS-B weather; see Fragmentation below |
| `0BEE0020` | Control | write, write-no-response | Vendor TLV commands (config, filters); replies come as vendor messages on Status |

Also implement the standard **Device Information Service** (0x180A) with
model, firmware revision, and serial; and **Battery Service** (0x180F) if
the hardware is battery-powered.

### Payload rules

- On Traffic/Ownship/Status, every notification is exactly one complete
  GDL90 message: `0x7E, ID, payload, CRC-16, 0x7E` with standard byte
  stuffing. Atomic per notification — a client never needs to reassemble
  across notifications on these characteristics.
- Traffic/ownship/status messages are well under the 244-byte usable
  payload at MTU 247 (a traffic report is 30 bytes framed). Both sides
  SHOULD negotiate MTU 517 (Android maximum; iOS negotiates similar
  automatically) so uplink fragments are few.
- Traffic rate: one notification per received target update, coalesced to
  at most ~5 Hz per target. Ownship 1 Hz (if the receiver has GNSS),
  Status 1 Hz.
- Vendor status/config replies use GDL90 ID 0x65 (long-established vendor
  ID convention); clients that don't understand 0x65 will discard it
  harmlessly. Defined subtypes (byte after the message ID):
  - `0x01` **Per-band metrics** (1 Hz on Status): three little-endian u32
    valid-frame counts for the last reporting interval - 1090ES
    (squitter + extended squitter), 978 UAT ADS-B, 978 UAT uplink
    (FIS-B). Standard traffic reports erase the receive band and the
    heartbeat merges the counts, so this is how a client displays
    per-band totals (accumulate client-side).

### Fragmentation (Uplink characteristic only)

FIS-B uplink frames (~450 bytes framed, worst-case larger after byte
stuffing) exceed a single notification, so the Uplink characteristic
carries fragments with a 1-byte header:

    bit 7: first fragment of a message
    bit 6: last fragment of a message
    bits 0-5: sequence number, incremented per fragment, wraps mod 64

The remaining bytes are a slice of the framed GDL90 Uplink message. The
client resets its reassembly buffer on a `first` fragment, appends in
sequence order, and delivers the completed frame on `last`; any sequence
gap discards the partial message (the next uplink re-syncs). A message
that fits entirely in one notification has both `first` and `last` set.
The peripheral SHOULD size fragments to the connection's negotiated MTU
(payload = MTU - 3 - 1) and MUST NOT send uplink fragments on connections
with MTU < 100 (the default-MTU case where FIS-B would drown the link).
Uplink applies only where a 978 MHz uplink network exists (US FAA;
Canadian CIFIB stations, cifib.ca).

### FANET / multi-band targets

FANET, FLARM, or other non-transponder targets are converted by the
receiver into GDL90 Traffic Reports: ICAO address field carries the FANET
address with the address-type field set to `self-assigned`, emitter
category set appropriately (glider/ultralight/UAV), callsign from the
FANET name if broadcast. The EFB needs zero protocol knowledge of the
radio bands - a paraglider is just another traffic target.

## Client behavior (implemented in AvareX `lib/io/ble_receiver.dart`)

1. Scan filtered on the service UUID (NUS `6E400001-...` also accepted as
   a byte-stream fallback for SoftRF-class devices).
2. Connect with OS auto-reconnect, request MTU 247 (Android; iOS
   negotiates automatically).
3. Subscribe to Traffic, Ownship, and Status notifications; feed each
   payload to the standard GDL90 decoder.
4. Remember the device and reconnect automatically on app start / receiver
   power-up.

## Testing without firmware

Any BLE-peripheral-capable dev board (ESP32) can prototype the service by
replaying the captures in `tests/*.bin` (real GDL90 recordings): split at
0x7E frame boundaries, notify one message at a time with realistic
timing on the Traffic characteristic.
