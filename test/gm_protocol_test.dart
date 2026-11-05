// GM framing against the vectors published in the MemoMind SDK
// (GlassSDK/docs/WIRE_EXAMPLES.md and PROTOCOL.md). Those documents label
// every byte including both checksum bytes, so an encoder that reproduces
// them is right for reasons that do not depend on my reading of the prose.
import 'dart:typed_data';

import 'package:avaremp/io/gm_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String text) => Uint8List.fromList(text
    .split(RegExp(r'\s+'))
    .where((String s) => s.isNotEmpty)
    .map((String s) => int.parse(s, radix: 16))
    .toList());

String show(List<int> bytes) => bytes
    .map((int b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
    .join(' ');

void main() {

  group("frames match the published vectors", () {

    test("heartbeat", () {
      final List<Uint8List> frames = GmCodec.heartbeatFrames(1);
      expect(frames, hasLength(1));
      expect(show(frames.single), show(hex("FA 00 00 09 01 01 01 01 06")));
    });

    test("ASCII to an application channel", () {
      // PROTOCOL.md: "ABC" to channel 1 with event ID 1.
      final List<Uint8List> frames = GmCodec.applicationFrames(
          event: 1, channel: 1, payload: "ABC".codeUnits);
      expect(
          show(frames.single),
          show(hex("FA 00 00 16 01 0F 28 07 00 00 02 00 01 "
              "01 00 00 03 41 42 43 02 1C")));
    });

    test("Web Bridge clear", () {
      final List<Uint8List> frames =
          GmCodec.applicationFrames(event: 1, channel: 1, payload: const [0]);
      expect(
          show(frames.single),
          show(hex("FA 00 00 14 01 0F 28 07 00 00 02 00 01 "
              "01 00 00 01 00 01 52")));
    });

    test("Web Bridge text, which carries a longer payload", () {
      // Object 1 at x=10, y=20, 200x40, no border or radius, text "Hi".
      final List<int> payload = [
        1, 0x00, 0x0A, 0x00, 0x14, 0x00, 0xC8, 0x00, 0x28, 0, 0,
        0x48, 0x69,
      ];
      final List<Uint8List> frames =
          GmCodec.applicationFrames(event: 1, channel: 2, payload: payload);
      expect(
          show(frames.single),
          show(hex("FA 00 00 20 01 0F 28 07 00 00 02 00 02 "
              "01 00 00 0D 01 00 0A 00 14 00 C8 00 28 00 00 48 69 03 2B")));
    });
  });

  group("framing rules", () {

    test("the logical length is the message, not the frame", () {
      // At a 20-byte write limit each frame carries 11 body bytes, and a
      // 36-byte payload is a 46-byte body once its two TLVs are counted, so
      // it takes five frames - every one repeating the logical length and
      // the service, command and event of the whole message.
      final List<Uint8List> frames = GmCodec.applicationFrames(
          event: 7,
          channel: 0x5041,
          payload: List<int>.filled(36, 0xAB),
          frameBytes: 20);
      expect(frames.length, 5);
      final int logical = 6 + 4 + 36 + 9;
      for(final Uint8List frame in frames) {
        expect((frame[1] << 16) | (frame[2] << 8) | frame[3], logical);
        expect(frame[4], 7);
        expect(frame[5], GmCodec.serviceApplication);
        expect(frame[6], GmCodec.commandApplicationSend);
        expect(frame.length, lessThanOrEqualTo(20));
      }
      expect(frames[0][0], GmCodec.frameStart);
      expect(frames[1][0], 1);
      expect(frames[2][0], 2);
      expect(frames[3][0], 3);
      expect(frames[4][0], 4);
    });

    test("every frame carries its own checksum", () {
      for(final Uint8List frame in GmCodec.applicationFrames(
          event: 3,
          channel: 1,
          payload: List<int>.filled(30, 0x5A),
          frameBytes: 20)) {
        int sum = 0;
        for(int i = 0; i < frame.length - 2; i++) {
          sum += frame[i];
        }
        expect((frame[frame.length - 2] << 8) | frame[frame.length - 1],
            sum & 0xFFFF);
      }
    });

    test("an empty application payload is refused", () {
      // The runtime rejects it, so there is no point sending it.
      expect(() => GmCodec.applicationFrames(event: 1, channel: 1, payload: const []),
          throwsArgumentError);
    });

    test("a write limit below the envelope is refused", () {
      expect(
          () => GmCodec.frames(
              event: 1, service: 1, command: 1, frameBytes: 9),
          throwsArgumentError);
    });
  });

  group("reassembling the uplink", () {

    test("a single frame becomes a message", () {
      final GmReassembler r = GmReassembler();
      final GmMessage? m = r.feed(hex("FA 00 00 09 01 01 01 01 06"));
      expect(m, isNotNull);
      expect(m!.service, 0x01);
      expect(m.command, 0x01);
      expect(m.event, 1);
      expect(m.body, isEmpty);
    });

    test("a fragmented message is put back together", () {
      final List<Uint8List> frames = GmCodec.applicationFrames(
          event: 9,
          channel: 0x5041,
          payload: List<int>.generate(36, (int i) => i),
          frameBytes: 20);
      final GmReassembler r = GmReassembler();
      GmMessage? message;
      for(final Uint8List frame in frames) {
        message = r.feed(frame);
      }
      expect(message, isNotNull);
      expect(message!.channel, 0x5041);
      final GmTlv payload =
          message.tlvs.firstWhere((GmTlv t) => t.type == GmCodec.typeBytes);
      expect(payload.value, List<int>.generate(36, (int i) => i));
    });

    test("intermediate frames yield nothing", () {
      final List<Uint8List> frames = GmCodec.applicationFrames(
          event: 2, channel: 1, payload: List<int>.filled(40, 1), frameBytes: 20);
      final GmReassembler r = GmReassembler();
      expect(r.feed(frames.first), isNull);
    });

    test("a bad checksum is dropped, not decoded", () {
      final List<String> errors = [];
      final GmReassembler r = GmReassembler(onError: errors.add);
      final Uint8List frame = hex("FA 00 00 09 01 01 01 01 06");
      frame[frame.length - 1] = 0x07;
      expect(r.feed(frame), isNull);
      expect(errors, hasLength(1));
    });

    test("a continuation with no start is dropped", () {
      final List<String> errors = [];
      final GmReassembler r = GmReassembler(onError: errors.add);
      final List<Uint8List> frames = GmCodec.applicationFrames(
          event: 2, channel: 1, payload: List<int>.filled(40, 1), frameBytes: 20);
      expect(r.feed(frames[1]), isNull);
      expect(errors.single, contains("out of order"));
    });

    test("a fresh start abandons a partial message", () {
      final GmReassembler r = GmReassembler();
      final List<Uint8List> long = GmCodec.applicationFrames(
          event: 2, channel: 1, payload: List<int>.filled(40, 1), frameBytes: 20);
      expect(r.feed(long.first), isNull);
      // The glasses interleave nothing, but a reconnect can leave us mid
      // message; the next first frame must simply work.
      final GmMessage? m = r.feed(hex("FA 00 00 09 01 01 01 01 06"));
      expect(m, isNotNull);
      expect(m!.body, isEmpty);
    });
  });

  group("replies", () {

    test("the status byte of an acknowledgement is found", () {
      final Uint8List reply = GmCodec.frames(
        event: 4,
        service: GmCodec.serviceApplication,
        command: GmCodec.commandApplicationSend,
        body: GmCodec.int8Tlv(0),
      ).single;
      final GmMessage m = GmReassembler().feed(reply)!;
      expect(m.status, 0);
    });

    test("a TLV stream that was cut short does not yield a half TLV", () {
      final Uint8List body = GmCodec.tlv(GmCodec.typeBytes, [1, 2, 3, 4]);
      expect(GmCodec.parseTlvs(Uint8List.sublistView(body, 0, 6)), isEmpty);
    });
  });
}
