import 'dart:typed_data';
import 'package:avaremp/io/ble_receiver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reassembles GDL90 frames split across notifications', () {
    List<Uint8List> frames = [];
    StreamFramer f = StreamFramer((g) => frames.add(g), (n) {});
    // one heartbeat frame split into three chunks
    f.feed([0x7E, 0x00, 0x81]);
    expect(frames, isEmpty);
    f.feed([0x41, 0xDB, 0xD0]);
    expect(frames, isEmpty);
    f.feed([0x08, 0x02, 0xB3, 0x8B, 0x7E]);
    expect(frames.length, 1);
    expect(frames[0].first, 0x7E);
    expect(frames[0].last, 0x7E);
    expect(frames[0].length, 11);
  });

  test('handles shared/doubled flags between frames', () {
    List<Uint8List> frames = [];
    StreamFramer f = StreamFramer((g) => frames.add(g), (n) {});
    f.feed([0x7E, 1, 2, 3, 4, 0x7E, 0x7E, 5, 6, 7, 8, 0x7E]);
    expect(frames.length, 2);
    expect(frames[0].sublist(1, 5), [1, 2, 3, 4]);
    expect(frames[1].sublist(1, 5), [5, 6, 7, 8]);
  });

  test('extracts NMEA sentences and GDL90 from a mixed stream', () {
    List<Uint8List> frames = [];
    List<String> sentences = [];
    StreamFramer f = StreamFramer(
        (g) => frames.add(g), (n) => sentences.add(String.fromCharCodes(n)));
    f.feed("\$GPRMC,A,B,C*77\r\n".codeUnits);
    f.feed([0x7E, 0x14, 1, 2, 3, 0x7E]);
    f.feed("\$GPGGA,1,2".codeUnits);
    f.feed(",3*55\r\n".codeUnits);
    expect(sentences.length, 2);
    expect(sentences[0].startsWith("\$GPRMC"), isTrue);
    expect(sentences[1].startsWith("\$GPGGA"), isTrue);
    expect(frames.length, 1);
  });

  test('uplink reassembler joins fragments and drops on gaps', () {
    List<Uint8List> frames = [];
    UplinkReassembler r = UplinkReassembler((f) => frames.add(f));
    // single-fragment message: first+last, seq 0
    r.feed([0x80 | 0x40 | 0, 1, 2, 3]);
    expect(frames.length, 1);
    expect(frames[0], [1, 2, 3]);
    // two-fragment message: seq 5 then 6
    r.feed([0x80 | 5, 10, 11]);
    r.feed([0x40 | 6, 12, 13]);
    expect(frames.length, 2);
    expect(frames[1], [10, 11, 12, 13]);
    // gap: first seq 1, then seq 3 (2 lost) -> dropped, next message fine
    r.feed([0x80 | 1, 9]);
    r.feed([0x40 | 3, 9]);
    expect(frames.length, 2);
    r.feed([0x80 | 0x40 | 9, 7]);
    expect(frames.length, 3);
    expect(frames[2], [7]);
    // sequence wraps mod 64
    r.feed([0x80 | 63, 1]);
    r.feed([0x40 | 0, 2]);
    expect(frames.length, 4);
    expect(frames[3], [1, 2]);
  });

  test('drops noise and resyncs', () {
    List<Uint8List> frames = [];
    StreamFramer f = StreamFramer((g) => frames.add(g), (n) {});
    f.feed([9, 9, 9, 0x7E, 1, 2, 3, 4, 0x7E]);
    expect(frames.length, 1);
    // oversize garbage clears the buffer
    f.feed(List.filled(9000, 1));
    f.feed([0x7E, 4, 3, 2, 1, 0x7E]);
    expect(frames.length, 2);
  });
}
