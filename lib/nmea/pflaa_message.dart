import 'dart:math';

import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:avaremp/nmea/nmea_message.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

// FLARM dataport traffic sentence, as sent by FLARM / PowerFLARM / SoftRF
// units in NMEA mode:
//
//   $PFLAA,<AlarmLevel>,<RelativeNorth>,<RelativeEast>,<RelativeVertical>,
//          <IDType>,<ID>,<Track>,<TurnRate>,<GroundSpeed>,<ClimbRate>,
//          <AcftType>[,<NoTrack>,<Source>,<RSSI>]*hh
//
// Offsets are metres relative to the receiver's own position, so the sentence
// is converted to an absolute GDL90-style traffic report against the current
// ownship fix and fed into the shared traffic cache, where it gets the same
// map symbol, range filtering and audible alerts as ADS-B traffic.
class PFLAAMessage extends NmeaMessage {
  PFLAAMessage(super.type);

  static const double _ftPerM = 3.28084;
  static const double _fpmPerMps = 196.85;

  // FLARM aircraft type -> GDL90 emitter category
  static const Map<int, int> _emitters = {
    0x1: 9,  // glider / motor glider
    0x2: 1,  // tow / tug plane
    0x3: 7,  // helicopter / rotorcraft
    0x4: 11, // skydiver
    0x5: 1,  // drop plane
    0x6: 12, // hang glider
    0x7: 12, // paraglider
    0x8: 1,  // powered aircraft
    0x9: 2,  // jet aircraft
    0xA: 0,  // unknown / UFO
    0xB: 10, // balloon
    0xC: 10, // airship
    0xD: 14, // UAV
    0xF: 19, // static obstacle
  };

  TrafficReportMessage? traffic;

  @override
  void parse(String data) {
    List<String> tokens = data.split("*")[0].split(",");
    if (tokens.length < 12) {
      return;
    }
    try {
      int alarm = int.tryParse(tokens[1]) ?? 0;
      double relNorth = double.parse(tokens[2]);
      double relEast = double.parse(tokens[3]);
      double relVert = double.parse(tokens[4]);
      int idType = int.tryParse(tokens[5]) ?? 0;
      int id = int.tryParse(tokens[6], radix: 16) ?? 0;
      double track = double.tryParse(tokens[7]) ?? 0;
      double speed = double.tryParse(tokens[9]) ?? 0; // m/s
      double climb = double.tryParse(tokens[10]) ?? 0; // m/s
      int acftType = int.tryParse(tokens[11], radix: 16) ?? 0;

      Position own = Storage().position;
      if (own.latitude == 0 && own.longitude == 0) {
        return; // no ownship fix yet; offsets are meaningless
      }
      double lat = own.latitude + relNorth / 111320.0;
      double lon = own.longitude +
          relEast / (111320.0 * cos(own.latitude * pi / 180.0));

      TrafficReportMessage m = TrafficReportMessage(0x14);
      m.icao = id;
      m.addressType = idType == 1 ? 0 : 1; // ICAO or self-assigned
      m.coordinates = LatLng(lat, lon);
      m.altitude = (own.altitude + relVert) * _ftPerM;
      m.velocity = speed;
      m.verticalSpeed = climb * _fpmPerMps;
      m.heading = track;
      m.emitter = _emitters[acftType] ?? 0;
      m.alertStatus = alarm > 0 ? 1 : 0;
      m.airborne = speed > 2 || relVert.abs() > 30;
      traffic = m;
      Storage().trafficCache.putTraffic(m);
    } catch (e) {
      AppLog.logMessage("PFLAAMessage: invalid data $data");
    }
  }
}
