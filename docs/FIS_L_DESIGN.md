# FIS-L: Lite FIS-B over 915 MHz LoRa (design sketch)

Status: idea / pre-hardware. Companion to [BLE_ADSB_SERVICE.md](BLE_ADSB_SERVICE.md).

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

## Link budget sanity

- LoRa ~2-5 kbps effective at moderate SF; ISED RSS-247 (and FCC part 15)
  915 ISM: license-free, FHSS/digital modulation rules, no EU-style duty
  cycle - but the band is shared with FANET traffic beacons, and traffic
  MUST take priority. Weather airtime budget: low single-digit percent,
  scheduled to avoid FANET slots.
- METAR ~60 bytes compressed; 20 stations every 5 min is negligible
  airtime. TAFs similar.
- Coarse regional radar: quantized grid (e.g. 4-bit intensity) ~2 KB per
  update, every 5-10 min. LoRa frames are <=255 bytes, so products fragment
  across frames with a first/last/sequence header (same pattern as the BLE
  Uplink characteristic).

## Products (phased)

1. **METARs/TAFs** for stations within the ground station's region -
   trivial airtime, immediately useful.
2. **Surface weather service frames** - FANET already defines ground
   station wind/temp/humidity messages (type 4); use the existing slot for
   interoperability with soaring instruments, coordinate extensions with
   the FANET community rather than inventing parallel formats.
3. **Coarse NEXRAD/GeoMet radar** regional grid.
4. Maybe: AIRMET/SIGMET text, PIREP relay.

## What needs building (once 915 MHz radios are in hand)

- Ground station firmware: ESP32+SX126x, fetch (aviationweather.gov /
  Environment Canada GeoMet), encode FIS-B product frames, scheduled
  broadcast. Could run on a spare SoftRF card or ADSBee with a LoRa pant.
- Receiver side: SoftRF firmware addition (custom - stock SoftRF does not
  forward non-FANET frames) or ADSBee tri-band: receive weather frames,
  reassemble products, emit as GDL90 uplink over BLE.
- Nothing in AvareX, by design.

## Ground station implementation plan (farmtrx rtk base, planned)

The deployed PoE RTK base stations (ESP32-S3 + SX126x @ 915 MHz, internet
via Ethernet/WiFi, ESP-IDF 5.5 C++ firmware) already provide every layer
FIS-L needs. Plan (no code written yet; owner's production firmware):

1. New module `app/function/weather_broadcast/` following the existing
   module pattern: task gated on network events (like `self_ota`), fetches
   `aviationweather.gov/api/data/metar?ids=<stations>&format=raw&taf=true`
   every ~5 min via the existing `http::client`, emits FIS-L product
   frames (`['F','L'][ver][product_id][payload]`, product 1 = METAR/TAF
   text) as a new event-loop event.
2. LoRa service gains one event handler (mirroring its `data_rtcm`
   handler) queueing weather frames into the existing 8 KB send ring
   buffer. The firmware's 10-byte packet header (MAC, message number,
   first/last flags, packet number) already provides fragmentation and
   reassembly - the airborne receiver parses it exactly like the RTK
   rovers do.
3. Config via the firmware's LittleFS JSON + schema pattern (enabled,
   station list, fetch interval), surfaced in its web UI.
4. Channel: weather shares the RTK correction channel (same freq/SF/BW/CR)
   - receivers get it for free, rovers discard by magic bytes; airtime for
   text products is negligible. Radar later needs an airtime budget or a
   scheduled hop.

Airborne side unchanged from the sketch above: SoftRF firmware matches the
base's LoRa parameters, filters `FL` frames, reassembles, wraps as GDL90
uplink over the BLE Uplink characteristic.

## Posture

Unofficial advisory data, not for navigation, no certification claims -
extra information, same disclaimer as the rest of this project. Complements
CIFIB (cifib.ca): real 978 FIS-B where stations exist, FIS-L for the long
tail. Coordinate band usage with FANET/OGN community norms before
transmitting anything beyond test frames.
