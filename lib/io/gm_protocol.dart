import 'dart:typed_data';

// GM framing, the command protocol the MemoMind glasses speak over BLE GATT
// (and classic SPP). Published in the plugin-open-platform SDK under
// GlassSDK/docs/PROTOCOL.md; this is an independent Dart implementation of
// that byte contract, checked against the SDK's annotated wire vectors in
// test/gm_protocol_test.dart.
//
// A physical frame is:
//
//   FA | logical length (3, big-endian) | event | service | command
//      | body bytes | additive sum (2, big-endian)
//
// The first frame of a message starts with 0xFA and each continuation frame
// starts with its own index, 1 upward. The logical length is the whole
// message - every TLV byte plus one nine-byte envelope - repeated in every
// frame, so it is not the length of the frame it appears in. Each frame
// carries its own checksum: the additive sum of all preceding bytes of that
// frame, modulo 65536.
//
// Bodies are TLVs: one type byte, a 24-bit big-endian length, then the value.
// Integers are big-endian throughout, which is the opposite of the little
// endian CCCD and GDL90 values elsewhere in this app.

class GmTlv {
  final int type;
  final Uint8List value;

  const GmTlv(this.type, this.value);

  /// Big-endian unsigned read, for the INT8/INT16/INT32 types.
  int get asInt {
    int result = 0;
    for(final int byte in value) {
      result = (result << 8) | byte;
    }
    return result;
  }

  @override
  String toString() => "GmTlv(0x${type.toRadixString(16)}, ${value.length}B)";
}

/// One complete logical message, reassembled from one or more frames.
class GmMessage {
  final int event;
  final int service;
  final int command;
  final Uint8List body;

  const GmMessage({
    required this.event,
    required this.service,
    required this.command,
    required this.body,
  });

  List<GmTlv> get tlvs => GmCodec.parseTlvs(body);

  /// The status byte of a STATUS or INT8 reply, null when the message carries
  /// neither. A command acknowledgement is not proof that anything was drawn;
  /// it only says the frame arrived and parsed.
  int? get status {
    for(final GmTlv tlv in tlvs) {
      if(tlv.type == GmCodec.typeStatus || tlv.type == GmCodec.typeInt8) {
        return tlv.value.isEmpty ? null : tlv.value[0];
      }
    }
    return null;
  }

  /// Channel of an application message, null for anything else.
  int? get channel {
    if(service != GmCodec.serviceApplication) {
      return null;
    }
    for(final GmTlv tlv in tlvs) {
      if(tlv.type == GmCodec.typeInt16 && tlv.value.length == 2) {
        return tlv.asInt;
      }
    }
    return null;
  }

  @override
  String toString() => "GmMessage(event $event, service 0x"
      "${service.toRadixString(16).padLeft(2, '0')}, command 0x"
      "${command.toRadixString(16).padLeft(2, '0')}, ${body.length}B)";
}

class GmCodec {
  static const int frameStart = 0xFA;
  static const int headerBytes = 7;
  static const int sumBytes = 2;
  static const int envelopeBytes = 9;

  // TLV types, from GlassSDK/docs/PROTOCOL.md.
  static const int typeBytes = 0x01;
  static const int typeString = 0x02;
  static const int typeInt32 = 0x03;
  static const int typeJson = 0x05;
  static const int typeStatus = 0x06;
  static const int typeInt16 = 0x07;
  static const int typeInt8 = 0x08;

  // Services and commands used here.
  static const int serviceSystem = 0x01;
  static const int commandHeartbeat = 0x01;
  static const int serviceApplication = 0x0F;
  static const int commandApplicationSend = 0x28;
  static const int commandPluginReply = 0x29;

  /// The firmware ceiling, and the most a single frame may ever be.
  static const int maxFrameBytes = 512;

  static Uint8List tlv(int type, List<int> value) {
    final Uint8List out = Uint8List(4 + value.length);
    out[0] = type;
    out[1] = (value.length >> 16) & 0xFF;
    out[2] = (value.length >> 8) & 0xFF;
    out[3] = value.length & 0xFF;
    out.setRange(4, out.length, value);
    return out;
  }

  static Uint8List int8Tlv(int value) => tlv(typeInt8, [value & 0xFF]);

  static Uint8List int16Tlv(int value) =>
      tlv(typeInt16, [(value >> 8) & 0xFF, value & 0xFF]);

  /// The body of a message to a running plugin: the channel, then the
  /// application's own bytes. The payload must not be empty - the runtime
  /// rejects an empty application message.
  static Uint8List applicationBody(int channel, List<int> payload) {
    if(payload.isEmpty) {
      throw ArgumentError("an application message needs a payload");
    }
    final Uint8List head = int16Tlv(channel);
    final Uint8List tail = tlv(typeBytes, payload);
    final Uint8List out = Uint8List(head.length + tail.length);
    out.setRange(0, head.length, head);
    out.setRange(head.length, out.length, tail);
    return out;
  }

  /// Split one logical message into complete physical frames, each with its
  /// own header and checksum. [frameBytes] is the validated characteristic
  /// write limit: the caller must not slice a frame across two writes, because
  /// the firmware hands every write to the frame parser whole.
  static List<Uint8List> frames({
    required int event,
    required int service,
    required int command,
    List<int> body = const [],
    int frameBytes = maxFrameBytes,
  }) {
    if(frameBytes < 10 || frameBytes > maxFrameBytes) {
      throw ArgumentError("frame size must be 10..$maxFrameBytes");
    }
    final int logical = body.length + envelopeBytes;
    final int room = frameBytes - envelopeBytes;
    final List<Uint8List> out = [];
    int offset = 0;
    int index = 0;
    do {
      final int take = body.length - offset < room ? body.length - offset : room;
      final Uint8List frame = Uint8List(envelopeBytes + take);
      frame[0] = index == 0 ? frameStart : index;
      frame[1] = (logical >> 16) & 0xFF;
      frame[2] = (logical >> 8) & 0xFF;
      frame[3] = logical & 0xFF;
      frame[4] = event & 0xFF;
      frame[5] = service & 0xFF;
      frame[6] = command & 0xFF;
      frame.setRange(headerBytes, headerBytes + take,
          body.sublist(offset, offset + take));
      final int sum = _sum(frame, headerBytes + take);
      frame[headerBytes + take] = (sum >> 8) & 0xFF;
      frame[headerBytes + take + 1] = sum & 0xFF;
      out.add(frame);
      offset += take;
      index++;
    }
    while(offset < body.length);
    if(index > 239) {
      // Beyond this the frame index and the App's historical wrap behaviour
      // disagree; a bigger MTU or a smaller message is the answer.
      throw ArgumentError("message needs $index frames; negotiate a larger MTU");
    }
    return out;
  }

  /// One frame's worth of message to a running plugin.
  static List<Uint8List> applicationFrames({
    required int event,
    required int channel,
    required List<int> payload,
    int frameBytes = maxFrameBytes,
  }) =>
      frames(
        event: event,
        service: serviceApplication,
        command: commandApplicationSend,
        body: applicationBody(channel, payload),
        frameBytes: frameBytes,
      );

  static List<Uint8List> heartbeatFrames(int event) =>
      frames(event: event, service: serviceSystem, command: commandHeartbeat);

  static int _sum(Uint8List frame, int length) {
    int sum = 0;
    for(int i = 0; i < length; i++) {
      sum += frame[i];
    }
    return sum & 0xFFFF;
  }

  static List<GmTlv> parseTlvs(Uint8List body) {
    final List<GmTlv> out = [];
    int offset = 0;
    while(offset + 4 <= body.length) {
      final int type = body[offset];
      final int length =
          (body[offset + 1] << 16) | (body[offset + 2] << 8) | body[offset + 3];
      if(offset + 4 + length > body.length) {
        break;        // truncated: the caller reassembled too little
      }
      out.add(GmTlv(type, Uint8List.sublistView(body, offset + 4, offset + 4 + length)));
      offset += 4 + length;
    }
    return out;
  }
}

/// Collects uplink frames into logical messages. Notifications arrive one
/// complete frame at a time, but a message may span several, and the glasses
/// interleave unsolicited events with command replies.
class GmReassembler {
  final void Function(String message)? onError;

  int _logical = 0;
  int _event = 0;
  int _service = 0;
  int _command = 0;
  final List<int> _body = [];
  int _next = 0;

  GmReassembler({this.onError});

  void reset() {
    _logical = 0;
    _body.clear();
    _next = 0;
  }

  /// Feed one complete notification value. Returns a message once its last
  /// frame arrives, null while more is expected or the frame was unusable.
  GmMessage? feed(List<int> value) {
    if(value.length < GmCodec.envelopeBytes) {
      _fail("short frame (${value.length} bytes)");
      return null;
    }
    final Uint8List frame = Uint8List.fromList(value);
    final int declared = (frame[frame.length - 2] << 8) | frame[frame.length - 1];
    final int computed = GmCodec._sum(frame, frame.length - GmCodec.sumBytes);
    if(declared != computed) {
      _fail("checksum ${declared.toRadixString(16)} != "
          "${computed.toRadixString(16)}");
      reset();
      return null;
    }
    final int sequence = frame[0];
    final int logical = (frame[1] << 16) | (frame[2] << 8) | frame[3];
    final Uint8List chunk =
        Uint8List.sublistView(frame, GmCodec.headerBytes, frame.length - GmCodec.sumBytes);

    if(sequence == GmCodec.frameStart) {
      _logical = logical;
      _event = frame[4];
      _service = frame[5];
      _command = frame[6];
      _body.clear();
      _next = 1;
    }
    else if(_logical == 0 || sequence != _next) {
      // A continuation with no start, or out of order: the earlier partial
      // message is gone, and guessing at its remainder would be worse.
      _fail("frame $sequence out of order");
      reset();
      return null;
    }
    else {
      _next++;
    }
    _body.addAll(chunk);

    if(_body.length + GmCodec.envelopeBytes < _logical) {
      return null;
    }
    final GmMessage message = GmMessage(
      event: _event,
      service: _service,
      command: _command,
      body: Uint8List.fromList(_body),
    );
    reset();
    return message;
  }

  void _fail(String why) => onError?.call(why);
}
