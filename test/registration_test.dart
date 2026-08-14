import 'package:avaremp/gdl90/message_factory.dart';
import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TrafficReportMessage m(int icao) {
    final t = TrafficReportMessage(MessageType.trafficReport);
    t.icao = icao;
    return t;
  }

  test('display id: derived Canadian registration, else hex', () {
    expect(m(0xC00001).displayId, "C-FAAA");
    expect(m(0xC00001 + 25).displayId, "C-FAAZ");
    expect(m(0xC00001 + 17575).displayId, "C-FZZZ");
    expect(m(0xC00001 + 17576).displayId, "C-GAAA");
    expect(m(0xC00001 + 35151).displayId, "C-GZZZ");
    expect(m(0xC09000).displayId, "C09000"); // outside the algorithmic block
    expect(m(0xA12345).displayId, "A12345"); // US block: hex for now
    final withCall = m(0xC00001);
    withCall.callSign = "MRFHS65";
    expect(withCall.displayId, "MRFHS65"); // broadcast callsign wins
  });
}
