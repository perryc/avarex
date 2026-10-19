import 'package:avaremp/utils/app_log.dart';
import 'package:avaremp/nmea/nmea_message.dart';
import 'package:avaremp/storage.dart';
import 'package:latlong2/latlong.dart';

class RMCMessage extends NmeaMessage {
  RMCMessage(super.type);

  LatLng coordinate = const LatLng(0, 0);
  /// Ground speed in m/s and true track in degrees, kept as doubles so an
  /// RTK receiver's resolution is not thrown away.
  double speed = 0;
  double track = 0;

  @override
  void parse(String data) {
    List<String> tokens = data.split(",");

    if (tokens.length < 9) {
      return;
    }

    double tmp;
    double tmp1;
    try {
      tmp = double.parse(tokens[3]);
      tmp1 = (tmp.toInt() ~/ 100).toDouble();
      double lat = (tmp - (tmp1 * 100.0)) / 60 + tmp1;
      if (tokens[4] == "S") {
        lat = -lat;
      }

      tmp = double.parse(tokens[5]);
      tmp1 = (tmp.toInt() ~/ 100).toDouble();
      double lon = (tmp - (tmp1 * 100.0)) / 60 + tmp1;
      if (tokens[6] == "W") {
        lon = -lon;
      }

      coordinate = LatLng(lat, lon);

      speed = double.parse(tokens[7]) * Storage().units.toMps;
      track = tokens[8].trim().isEmpty ? 0 : double.parse(tokens[8]);

    }
    catch (e) {
      AppLog.logMessage("RMCMessage: invalid data $data");
    }

  }

}