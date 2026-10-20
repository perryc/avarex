# FIS-L: Lite FIS-B over 915 MHz LoRa (design sketch)

Status: design / first 915 MHz radios in hand (two Seeed MeshTracker X1
running SoftRF, 2026-10). Companion to [BLE_ADSB_SERVICE.md](BLE_ADSB_SERVICE.md).

## The idea

Broadcast a lightweight FIS-B-style weather uplink on the license-free
915 MHz ISM band using LoRa, receivable by the same $42-class radios
(SoftRF and the planned ADSBee tri-band) that already handle FANET traffic.
Ground stations are cheap ESP32+LoRa boards with an internet connection -
the CIFIB volunteer model at ~$50/station instead of a 978 MHz transmitter,
filling coverage gaps (cottage strips, backcountry) that will never justify
real FIS-B infrastructure.

## Why the hard half already exists

The airborne chain is already built and hardware-proven:

    LoRa radio -> GDL90 Uplink frame -> BLE Uplink characteristic
    (fragmented, see BLE spec) -> AvareX FIS-B decode (NexradCache etc.)

If the ground station encodes **genuine FIS-B product frames** (DO-358
APDU formats, the same products CIFIB transmits on 978), the receiver only
wraps received bytes as GDL90 uplink messages and nothing downstream
changes: not the receiver firmware's uplink path, not the BLE interface,
not the EFB. Same weather, different last mile.

## Channel: ride the FANET channel

The ground station is a FANET node. It transmits on the FANET North
America zone parameters, so every SoftRF / X1 already tuned for FANET
traffic hears it with no second radio configuration:

| Parameter | FANET zone 2 (Americas) |
|---|---|
| Frequency | 920.8 MHz, fixed |
| Modulation | LoRa, SF7, 500 kHz bandwidth, explicit header, CRC |
| Coding rate | 4/5 (stiffens to 4/8 as neighbour count rises) |
| Sync word | 0xF1 |
| Tx power | ~15 dBm (FANET norm; RSS-247 allows far more) |
| Duty cycle | < 1 % per node (EU rule, carried into the Americas zone as a norm) |

Why this and not a private channel:

- **One radio setting for traffic and weather.** The X1 has a single radio
  and SoftRF selects exactly one protocol. A weather uplink on a different
  frequency, bandwidth or spreading factor would be inaudible to an aircraft
  running FANET for air-to-air traffic. On the FANET channel it costs the
  aircraft nothing.
- **Regulatory fit.** FANET uses 500 kHz bandwidth in the Americas zone so
  it qualifies as a digital transmission system under ISED RSS-247 (and FCC
  15.247): fixed frequency, no hopping required, up to 1 W. A ground
  station on the same parameters inherits that.
- **Precedent.** FANET already defines ground weather stations (service
  type 4) and ground-station forwarding; Skytraxx / Burnair stations exist
  in Europe. FIS-L extends that model with text and gridded products.

### How FANET shares the channel (vs UAT)

UAT is GPS-synchronised TDMA: a 1 s frame with a reserved 176 ms ground
uplink segment (32 slots) and 3951 aircraft message-start opportunities
after it. FIS-B airtime is protected; nothing airborne transmits in it.

FANET has no time sync and no slots. From the reference MAC
(fanet-stm32 `fmac.cpp`):

- Listen-before-talk with channel activity detection. Busy -> random
  backoff of 64..4096 ms with binary exponential growth, then listen again.
- After a transmit, hold off for ~15 ms + 2 ms per byte sent.
- Tracking beacons ~every 5 s (adaptive), service packets ~every 40 s.
- Forwarders relay with the forward bit and a random delay.

Consequence: the weather station is one more contending node with **no
protected window**. Its airtime competes with position beacons, so the
budget below is a hard ceiling, traffic beacons take priority by design
(CSMA, short frames), and bulk products are spread out rather than burst.

## Frame format

Standard FANET header, new packet type for FIS-L products, plus the
existing service type for the station's own surface weather.

    [0]    FANET header: ext-header bit, forward bit, type
    [1-3]  source address: manufacturer ID + 16-bit station ID
    [4..]  payload (type dependent)

- **Type 4 (service), unchanged spec.** The station's own position, wind,
  temperature, humidity, pressure, every ~40 s. Existing soaring
  instruments display it today; no coordination needed.
- **Type `FIS_L` (new, >= 10; number to be agreed with the FANET
  maintainers).** Payload:

      [ver][product_id][frag: bit7 first, bit6 last, bits0-5 seq][APDU bytes]

  `product_id` and the APDU bytes follow DO-358 so the receiver passes them
  through unchanged; the one-byte fragment header is the same scheme the
  BLE Uplink characteristic uses. Max LoRa payload leaves ~240 bytes per
  frame after the FANET header. Unknown types are silently dropped by
  stock FANET receivers, so FIS-L frames never confuse a vario.
- **Forward bit set** so other ground stations (and nothing airborne -
  aircraft do not forward) extend coverage.
- Manufacturer ID: request one from the FANET maintainers; use a
  non-conflicting development ID until then.

Type 3 (free-text message) was considered and rejected: a METAR fits, but
every FANET instrument in range would pop it up as a chat message.

## Airtime budget

At SF7 / BW 500 kHz / CR 4/5 a full 240-byte frame is ~75 ms on air; a
20-byte tracking beacon ~20 ms.

| Load | Airtime |
|---|---|
| One aircraft tracking beacon every 5 s | ~0.4 % |
| Station service packet every 40 s | < 0.1 % |
| 20 METARs + TAFs (~60 B compressed each) every 5 min, ~40 frames | ~1 % |
| Coarse regional radar, 4-bit grid ~2 KB every 10 min, ~9 frames | ~0.1 % |

So a text-products station loads the channel like two or three extra
aircraft, right at the FANET per-node norm. Spread products across the
interval (one frame every few seconds) rather than bursting them. Radar at
higher resolution or shorter intervals needs its own budget decision; the
grid above is the ceiling until the channel is measured in practice.

## Products (phased)

1. **Surface weather (type 4)** for the station itself - zero new code on
   the receiving side, interoperable with soaring instruments.
2. **METARs/TAFs** for stations within the ground station's region -
   trivial airtime, immediately useful.
3. **Coarse NEXRAD/GeoMet radar** regional grid, fragmented.
4. Maybe: AIRMET/SIGMET text, PIREP relay.

## What needs building

- **Ground station firmware**: a FANET node on ESP32+SX126x (or a spare X1
  / SoftRF board in a custom build): fetch (aviationweather.gov /
  Environment Canada GeoMet), encode DO-358 product frames, fragment,
  CSMA transmit at the FANET parameters, plus the type 4 service packet.
- **Receiver side**: SoftRF firmware addition - stock SoftRF decodes FANET
  tracking and drops everything else. Add: recognise the FIS-L type,
  reassemble fragments, wrap as a GDL90 Uplink (0x07) message and emit it
  on the BLE Uplink characteristic exactly as the ADSBee does for 978.
  The ADSBee tri-band gets the same path when its LoRa radio lands.
- **Nothing in AvareX**, by design.

## Ground station on the farmtrx RTK base fleet (revised)

The deployed PoE RTK base stations (ESP32-S3 + SX126x @ 915 MHz, internet
via Ethernet/WiFi, ESP-IDF 5.5 C++ firmware) still provide the enclosure,
power, internet and module pattern FIS-L wants. What changed: the base's
LoRa radio runs the RTCM correction channel at its own frequency / SF /
BW, and the FANET channel needs different settings. One SX126x cannot
serve both at once without time-sharing, which would steal RTCM airtime
from the rovers. Options, in order of preference:

1. **Second SX126x module** on the base, dedicated to FANET. The
   `weather_broadcast` module (task gated on network events like
   `self_ota`, fetch via the existing `http::client` every ~5 min) drives
   it directly with the FANET MAC; the RTCM channel is untouched.
2. **Separate ground station board** (ESP32+SX126x, or a spare X1) co-located
   with the base, sharing its network. Simplest to prototype; the module
   above becomes a small standalone firmware.
3. **Time-share the base radio** (switch parameters, send a weather frame,
   switch back). Rejected unless measured RTCM loss is negligible.

Config via the firmware's LittleFS JSON + schema pattern (enabled, station
list, fetch interval, FANET station ID), surfaced in its web UI.

### Superseded: weather on the RTK correction channel

The first plan put FIS-L frames (`['F','L'][ver][product_id][payload]`)
on the RTCM channel, reusing its 10-byte packet header for fragmentation.
It is kept here for the record: it is the cheapest change to the base
firmware, but it requires the aircraft radio to be tuned to the RTK
channel, which an X1 running FANET traffic cannot be. Only viable if the
aircraft carries a second receiver.

## Posture

Unofficial advisory data, not for navigation, no certification claims -
extra information, same disclaimer as the rest of this project. Complements
CIFIB (cifib.ca): real 978 FIS-B where stations exist, FIS-L for the long
tail. Coordinate the packet type and manufacturer ID with the FANET
maintainers, and respect the FANET airtime norms, before transmitting
anything beyond test frames.
