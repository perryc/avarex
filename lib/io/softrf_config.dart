import 'package:avaremp/storage.dart';

/// SoftRF settings sentences ($PSRFC / $PSRFA) as sent over the BLE serial
/// link, so AvareX can put a SoftRF unit straight into the configuration the
/// traffic link needs and give it the aircraft's own ICAO address.
///
/// Field codes follow software/app/interface/SoftRF.h in the SoftRF tree.
/// $PSRFA is only understood by the perryc/SoftRF aircraft-address build.
class SoftRfConfig {

  // $PSRFC protocol
  static const int protocolLegacy = 0; // FLARM-compatible, 2-FSK
  static const int protocolOgntp = 1;
  static const int protocolFanet = 5;  // LoRa, longest range
  static const int bandUs = 2;         // US/CA 915 MHz
  static const int aircraftPowered = 8;
  static const int alarmVector = 2;
  static const int txPowerFull = 0;
  static const int volumeFull = 0;
  static const int ledOff = 2;
  static const int outputBluetooth = 5;

  static const Map<int, String> protocolNames = {
    protocolLegacy: "Legacy (FLARM)",
    protocolOgntp: "OGNTP",
    protocolFanet: "FANET",
  };

  /// NMEA framing with the XOR checksum, CRLF terminated.
  static String sentence(String body) {
    int sum = 0;
    for (final int c in body.codeUnits) {
      sum ^= c;
    }
    return "\$$body*${sum.toRadixString(16).toUpperCase().padLeft(2, '0')}\r\n";
  }

  /// Set the 24-bit ICAO address (0 reverts the unit to its chip-derived ID)
  /// and the FANET/1090ES receive mux flag (LR2021 units on FANET only).
  static String setAddress(int icao, {bool mux = false}) =>
      sentence("PSRFA,1,${(icao & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')},${mux ? 1 : 0}");

  static String queryAddress() => sentence("PSRFA,?");
  static String querySettings() => sentence("PSRFC,?");

  /// Settings for the AvareX 915 MHz traffic link: chosen radio protocol in
  /// the US/CA band, powered aircraft, vector alarms, full power, GNSS and
  /// FLARM NMEA plus GDL90 over Bluetooth, nothing hidden. The unit restarts.
  static String settings({int protocol = protocolFanet, int aircraftType = aircraftPowered}) {
    final List<int> f = [
      1,            // PSRFC version
      0,            // mode: normal
      protocol,
      bandUs,
      aircraftType,
      alarmVector,
      txPowerFull,
      volumeFull,
      ledOff,
      1, 0, 1, 0,   // NMEA: GNSS on, private off, legacy (FLARM) on, sensors off
      outputBluetooth, // NMEA output
      outputBluetooth, // GDL90 output
      0,            // dump1090 off
      0, 0,         // stealth off, no-track off
      0,            // power save none
    ];
    return sentence("PSRFC,${f.join(',')}");
  }

  /// ICAO address for a registration: Canadian marks via the register or the
  /// C-F/C-G allocation formula; otherwise null.
  static int? icaoForRegistration(String registration) =>
      Storage().canadaRegistry.lookupMark(registration);

  /// Parsed `$PSRFA,1,hhhhhh[,mux]` reply, or null.
  static int? parseAddressReply(String nmea) {
    final RegExpMatch? m = RegExp(r'^\$PSRFA,1,([0-9A-Fa-f]{6})(?:,|\*)').firstMatch(nmea.trim());
    return m == null ? null : int.parse(m.group(1)!, radix: 16);
  }

  /// Mux flag from a `$PSRFA,1,hhhhhh,m` reply; null when absent (older firmware).
  static bool? parseMuxReply(String nmea) {
    final RegExpMatch? m = RegExp(r'^\$PSRFA,1,[0-9A-Fa-f]{6},([01])\*').firstMatch(nmea.trim());
    return m == null ? null : m.group(1) == "1";
  }

  /// Human summary of a "$PSRFC,1,..." reply ("FANET, US/CA, GDL90 BT"), or null.
  static String? describeSettingsReply(String nmea) {
    final String s = nmea.trim();
    if (!s.startsWith("\$PSRFC,1,")) {
      return null;
    }
    final List<String> f = s.split("*")[0].split(",");
    if (f.length < 20) {
      return null;
    }
    final int protocol = int.tryParse(f[3]) ?? -1;
    final int band = int.tryParse(f[4]) ?? -1;
    final int gdl90 = int.tryParse(f[15]) ?? -1;
    final int tx = int.tryParse(f[7]) ?? -1;
    return "${protocolNames[protocol] ?? "protocol $protocol"}, "
        "${band == bandUs ? "US/CA" : "band $band"}, "
        "${tx == txPowerFull ? "full power" : tx == 2 ? "TX off" : "low power"}, "
        "GDL90 ${gdl90 == outputBluetooth ? "over BT" : "not on BT"}";
  }
}
