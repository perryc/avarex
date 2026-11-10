import 'package:avaremp/io/softrf_config.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("sentences carry NMEA checksums", () {
    expect(SoftRfConfig.setAddress(0xC02076), startsWith("\$PSRFA,1,C02076,0*"));
    expect(SoftRfConfig.setAddress(0xC02076, mux: true), startsWith("\$PSRFA,1,C02076,1*"));
    expect(SoftRfConfig.queryAddress(), "\$PSRFA,?*45\r\n");
    final String s = SoftRfConfig.settings();
    expect(s, startsWith("\$PSRFC,1,0,5,2,8,2,0,0,2,1,0,1,0,5,5,0,0,0,0*"));
    expect(SoftRfConfig.settings(protocol: SoftRfConfig.protocolLegacy),
        startsWith("\$PSRFC,1,0,0,2,8,"));
  });

  test("replies parse", () {
    expect(SoftRfConfig.parseAddressReply("\$PSRFA,1,C02076*17"), 0xC02076);
    expect(SoftRfConfig.parseAddressReply("\$PSRFA,1,C02076,1*3A"), 0xC02076);
    expect(SoftRfConfig.parseMuxReply("\$PSRFA,1,C02076,1*3A"), isTrue);
    expect(SoftRfConfig.parseMuxReply("\$PSRFA,1,C02076*17"), isNull);
    expect(SoftRfConfig.parseAddressReply("\$PSRFC,1,0*00"), isNull);
    expect(SoftRfConfig.describeSettingsReply("\$PSRFC,1,0,5,2,8,2,0,0,2,1,0,1,0,5,5,0,0,0,0*1A"),
        "FANET, US/CA, full power, GDL90 over BT");
    expect(SoftRfConfig.describeSettingsReply("\$PSRFC,1,0,0,1,8,2,2,0,2,1,0,1,0,5,0,0,0,0,0*1A"),
        "Legacy (FLARM), band 1, TX off, GDL90 not on BT");
  });

  test("registration resolves by formula, or not at all without a register", () {
    // No national register is installed in this build, so EmptyAircraftRegistry
    // answers nothing and only the formulas and a bare address can resolve.
    expect(Storage().aircraftRegistry.count, 0);
    expect(Storage().aircraftRegistry.lookupIcao("C-FMHP"), isNull);
    expect(SoftRfConfig.icaoForRegistration("N12345"), 0xA061D9); // US formula
    expect(SoftRfConfig.icaoForRegistration("A12DB5"), 0xA12DB5); // bare address
    expect(SoftRfConfig.icaoForRegistration("C-FMHP"), isNull);   // needs a register
    expect(SoftRfConfig.icaoForRegistration("G-ABCD"), isNull);
    expect(SoftRfConfig.icaoForRegistration(""), isNull);
  });
  test('N-numbers resolve to ICAO addresses', () {
    expect(SoftRfConfig.icaoForNNumber("N1"), 0xA00001);
    expect(SoftRfConfig.icaoForNNumber("N101NN"), 0xA009A4);
    expect(SoftRfConfig.icaoForNNumber("N1049A"), 0xA01724);
    expect(SoftRfConfig.icaoForNNumber("N105GC"), 0xA017E0);
    expect(SoftRfConfig.icaoForNNumber("N987JT"), 0xADC5FF);
    expect(SoftRfConfig.icaoForNNumber("N96FF"), 0xAD5A50);
    expect(SoftRfConfig.icaoForNNumber("N0ABC"), isNull);
    expect(SoftRfConfig.icaoForNNumber("N1IAB"), isNull);
  });
}
