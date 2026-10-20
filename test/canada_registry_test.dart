import 'dart:convert';

import 'package:avaremp/canada/canada_registry.dart';
import 'package:avaremp/gdl90/message_factory.dart';
import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 47 columns like carscurr.txt; only MARK(0), COMMON(3), MODEL(4), MODE_S(42) matter
  String row(String mark, String common, String model, int icao) {
    final List<String> cols = List.filled(47, "");
    cols[0] = mark;
    cols[1] = "Continuing Registration";
    cols[3] = common;
    cols[4] = model;
    cols[42] = icao.toRadixString(2).padLeft(24, "0");
    return cols.map((c) => '"$c"').join(",");
  }

  test("register dump parses marks, models and Mode S addresses", () {
    final String text = [
      row("FMHP", "Van'S", "RV-10", 0xC02076),
      row("IAA", "Piper", "PA-12", 0xC01521),
      row("GBAD", "Cessna", "  172   N  ", 0xC05000),
      '"XXXX","bad","","","","no mode s"', // short/invalid row skipped
    ].join("\r\n");
    final rows = CanadaRegistry.parse(latin1.encode(text));
    expect(rows.length, 3);
    expect(rows[0]["ICAO"], 0xC02076);
    expect(rows[0]["Mark"], "C-FMHP");
    expect(rows[0]["Model"], "RV-10");
    expect(rows[1]["Mark"], "C-IAA"); // ultralight, outside the formula block
    expect(rows[2]["Model"], "172 N");
  });

  test("traffic labels resolve through the register and drop SoftRF placeholders", () {
    Storage().canadaRegistry.seed({
      0xC02076: const CanadaAircraft("C-FMHP", "RV-10", "VAN'S"),
      0xC01521: const CanadaAircraft("C-IAA", "PA-12", "PIPER"),
    });
    final t = TrafficReportMessage(MessageType.trafficReport);
    t.icao = 0xC02076;
    t.callSign = "FAC02076"; // SoftRF: protocol prefix + hex address
    expect(t.effectiveCallSign, "");
    expect(t.displayId, "C-FMHP");
    expect(t.displayLabel, "C-FMHP RV-10");

    t.callSign = "FLC02076";
    expect(t.displayId, "C-FMHP");

    t.callSign = "FAC02077"; // prefix+hex that is NOT our address: a real callsign
    expect(t.effectiveCallSign, "FAC02077");

    final u = TrafficReportMessage(MessageType.trafficReport);
    u.icao = 0xC01521; // C-IAA: formula cannot derive this, register can
    expect(u.displayId, "C-IAA");
    expect(u.displayLabel, "C-IAA PA-12");

    final v = TrafficReportMessage(MessageType.trafficReport);
    v.icao = 0xC00001; // not in register: formula still works, no model
    expect(v.displayId, "C-FAAA");
    expect(v.displayLabel, "C-FAAA");
    Storage().canadaRegistry.clear();
  });
}
