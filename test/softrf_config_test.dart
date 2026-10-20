import 'package:avaremp/canada/canada_registry.dart';
import 'package:avaremp/io/softrf_config.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("sentences carry NMEA checksums", () {
    expect(SoftRfConfig.setAddress(0xC02076), "\$PSRFA,1,C02076*17\r\n");
    expect(SoftRfConfig.queryAddress(), "\$PSRFA,?*45\r\n");
    final String s = SoftRfConfig.settings();
    expect(s, startsWith("\$PSRFC,1,0,5,2,8,2,0,0,2,1,0,1,0,5,5,0,0,0,0*"));
    expect(SoftRfConfig.settings(protocol: SoftRfConfig.protocolLegacy),
        startsWith("\$PSRFC,1,0,0,2,8,"));
  });

  test("replies parse", () {
    expect(SoftRfConfig.parseAddressReply("\$PSRFA,1,C02076*17"), 0xC02076);
    expect(SoftRfConfig.parseAddressReply("\$PSRFC,1,0*00"), isNull);
    expect(SoftRfConfig.describeSettingsReply("\$PSRFC,1,0,5,2,8,2,0,0,2,1,0,1,0,5,5,0,0,0,0*1A"),
        "FANET, US/CA, full power, GDL90 over BT");
    expect(SoftRfConfig.describeSettingsReply("\$PSRFC,1,0,0,1,8,2,2,0,2,1,0,1,0,5,0,0,0,0,0*1A"),
        "Legacy (FLARM), band 1, TX off, GDL90 not on BT");
  });

  test("registration resolves through register then formula", () {
    Storage().canadaRegistry.seed({0xC01521: const CanadaAircraft("C-IAA", "PA-12", "PIPER")});
    expect(SoftRfConfig.icaoForRegistration("c-iaa"), 0xC01521);
    expect(SoftRfConfig.icaoForRegistration("CFMHP"), 0xC02076); // formula
    expect(SoftRfConfig.icaoForRegistration("C-GZZZ"), 0xC00001 + 35151);
    expect(SoftRfConfig.icaoForRegistration("N12345"), isNull);
    expect(SoftRfConfig.icaoForRegistration(""), isNull);
    Storage().canadaRegistry.clear();
  });
}
