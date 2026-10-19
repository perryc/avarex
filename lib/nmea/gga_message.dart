import 'package:avaremp/utils/app_log.dart';
import 'package:avaremp/nmea/nmea_message.dart';
import 'package:avaremp/storage.dart';
import 'package:latlong2/latlong.dart';

class GGAMessage extends NmeaMessage {
  GGAMessage(super.type);

  LatLng coordinate = const LatLng(0, 0);
  /// Altitude above mean sea level in metres (field 9). Kept as a double so an
  /// RTK receiver's centimetre altitude survives for precision guidance.
  double altitude = -100;
  /// NMEA fix quality (field 6): 0 none, 1 GPS, 2 DGPS, 4 RTK fixed,
  /// 5 RTK float, 6 dead reckoning, 7 manual, 8 simulated.
  int fixQuality = 0;
  int satellites = 0;
  double hdop = 99;
  /// Geoid separation in metres (field 11), 0 when not provided.
  double geoidSeparation = 0;
  /// Age of differential corrections in seconds (field 13), null when absent.
  double? diffAge;

  @override
  void parse(String data) {
    List<String> tokens = data.split(",");

    if (tokens.length < 11) {
      return;
    }

    double tmp;
    double tmp1;
    try {
      tmp = double.parse(tokens[2]);
      tmp1 = (tmp.toInt() ~/ 100).toDouble();
      double lat = (tmp - (tmp1 * 100.0)) / 60 + tmp1;
      if (tokens[3] == "S") {
        lat = -lat;
      }

      tmp = double.parse(tokens[4]);
      tmp1 = (tmp.toInt() ~/ 100).toDouble();
      double lon = (tmp - (tmp1 * 100.0)) / 60 + tmp1;
      if (tokens[5] == "W") {
        lon = -lon;
      }

      coordinate = LatLng(lat, lon);

      double alt = double.parse(tokens[9]);
      if(tokens[10] != "M") {
        altitude = alt * Storage().units.mToF;
      }
      else {
        altitude = alt;
      }
      fixQuality = int.tryParse(tokens[6].trim()) ?? 0;
      satellites = int.tryParse(tokens[7].trim()) ?? 0;
      hdop = double.tryParse(tokens[8].trim()) ?? 99;
      if (tokens.length > 11) {
        geoidSeparation = double.tryParse(tokens[11].trim()) ?? 0;
      }
      if (tokens.length > 13) {
        // last field carries the checksum suffix when no station id follows
        final String age = tokens[13].split('*').first.trim();
        diffAge = age.isEmpty ? null : double.tryParse(age);
      }
    }
    catch (e) {
      AppLog.logMessage("GGAMessage: invalid data $data");
    }
  }

}