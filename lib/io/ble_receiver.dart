import 'dart:async';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:universal_io/io.dart';

// BLE ADS-B receiver client (ADSBee and similar open receivers).
//
// Supports multiple simultaneous receivers - e.g. an ADSBee 1090U for
// 1090ES and a SoftRF unit for FANET/LoRa - each on its own BLE link,
// merged into one traffic picture.
//
// Primary interface is the ADS-B Receiver GATT service (see
// docs/BLE_ADSB_SERVICE.md): typed notify characteristics for traffic,
// ownship, and status. Each notification carries one complete framed GDL90
// message, so payloads pass straight to the decoder. A Nordic UART Service
// fallback supports byte-stream devices (SoftRF, BLE-serial bridges);
// those are reassembled per-link into complete GDL90 frames / NMEA
// sentences before being merged, so interleaving between devices can never
// corrupt a frame.
//
// Works on iOS/iPadOS as well as Android, and leaves Wi-Fi free for
// internet (phone hotspot).
class BleReceiver {

  // ADS-B Receiver Service ("0BEE"/"1090" - see docs/BLE_ADSB_SERVICE.md)
  static final Guid adsbService = Guid("0BEE0001-1090-46F0-A9AC-52D6BE4C29CC");
  static final Guid adsbTraffic = Guid("0BEE0010-1090-46F0-A9AC-52D6BE4C29CC"); // notify
  static final Guid adsbOwnship = Guid("0BEE0011-1090-46F0-A9AC-52D6BE4C29CC"); // notify
  static final Guid adsbStatus = Guid("0BEE0012-1090-46F0-A9AC-52D6BE4C29CC"); // notify
  static final Guid adsbUplink = Guid("0BEE0013-1090-46F0-A9AC-52D6BE4C29CC"); // notify, fragmented (FIS-B)
  static final Guid adsbControl = Guid("0BEE0020-1090-46F0-A9AC-52D6BE4C29CC"); // write

  // Nordic UART Service fallback (SoftRF, BLE-serial bridges)
  static final Guid nusService = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid nusTx = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"); // notify
  static final Guid nusRx = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); // write

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  final Map<String, BleLink> _links = {};
  final ValueNotifier<int> change = ValueNotifier(0); // links added/removed/status
  final ValueNotifier<bool> scanning = ValueNotifier(false);

  List<BleLink> get links => _links.values.toList();
  bool get anyConnected => _links.values.any((l) => l.isConnected);

  // scan for ADS-B receivers (and NUS fallback devices); results stream in
  // FlutterBluePlus.scanResults
  Future<void> scan() async {
    if(!supported || scanning.value) {
      return;
    }
    try {
      scanning.value = true;
      await FlutterBluePlus.startScan(
          withServices: [adsbService, nusService],
          timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
    }
    catch(e) {
      AppLog.logMessage("BLE scan failed: $e");
    }
    finally {
      scanning.value = false;
    }
  }

  // connect and remember the device for auto-reconnect
  Future<void> connect(BluetoothDevice device) async {
    if(_links.containsKey(device.remoteId.str)) {
      return;
    }
    _saveIds({..._savedIds(), device.remoteId.str});
    BleLink link = BleLink(device, this);
    _links[device.remoteId.str] = link;
    change.value++;
    await link.start();
  }

  // disconnect one device and forget it
  Future<void> disconnect(BleLink link) async {
    _saveIds(_savedIds()..remove(link.id));
    _links.remove(link.id);
    await link.stop();
    change.value++;
  }

  // reconnect to remembered devices (called from startIO)
  void startAutoConnect() {
    if(!supported) {
      return;
    }
    for(String id in _savedIds()) {
      if(_links.containsKey(id)) {
        continue;
      }
      try {
        BleLink link = BleLink(BluetoothDevice.fromId(id), this);
        _links[id] = link;
        link.start();
      }
      catch(e) {
        AppLog.logMessage("BLE auto-connect failed for $id: $e");
      }
    }
    if(_links.isNotEmpty) {
      change.value++;
    }
  }

  // send to all connected devices' control characteristics (autopilot data)
  Future<void> send(List<int> data) async {
    for(BleLink link in _links.values) {
      await link.send(data);
    }
  }

  Set<String> _savedIds() {
    String csv = Storage().settings.getBleDeviceId();
    return csv.isEmpty ? {} : csv.split(",").toSet();
  }

  void _saveIds(Set<String> ids) {
    Storage().settings.setBleDeviceId(ids.join(","));
  }
}

// one connected BLE receiver
class BleLink {

  BleLink(this._device, this._owner);

  final BluetoothDevice _device;
  final BleReceiver _owner;
  final ValueNotifier<String> status = ValueNotifier("Connecting");
  BluetoothCharacteristic? _control;
  final List<StreamSubscription<List<int>>> _dataSubs = [];
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  final StreamFramer _framer = StreamFramer(
      (frame) => Storage().gdl90Buffer.put(frame),
      (sentence) => Storage().nmeaBuffer.put(sentence));
  final UplinkReassembler _uplinkReassembler =
      UplinkReassembler((frame) => Storage().gdl90Buffer.put(frame));
  bool _running = false;

  String get id => _device.remoteId.str;
  String get name =>
      _device.platformName.isEmpty ? _device.remoteId.str : _device.platformName;
  bool get isConnected => _device.isConnected;

  Future<void> start() async {
    _running = true;
    _connectionSub = _device.connectionState.listen((state) async {
      if(state == BluetoothConnectionState.connected) {
        try {
          await _subscribe();
          status.value = "Connected";
        }
        catch(e) {
          AppLog.logMessage("BLE subscribe failed ($name): $e");
          status.value = "Error: $e";
        }
      }
      else if(state == BluetoothConnectionState.disconnected && _running) {
        status.value = "Reconnecting";
      }
      _owner.change.value++;
    });
    try {
      // autoConnect lets the OS re-establish the link whenever the receiver
      // powers up in range
      await _device.connect(autoConnect: true, mtu: null);
    }
    catch(e) {
      AppLog.logMessage("BLE connect failed ($name): $e");
      status.value = "Error: $e";
      _owner.change.value++;
    }
  }

  Future<void> _subscribe() async {
    if(Platform.isAndroid) {
      try {
        // 517 is the Android maximum; large MTU keeps FIS-B uplink fragments
        // to a minimum (iOS negotiates its own maximum automatically)
        await _device.requestMtu(517);
      }
      catch(_) {} // some stacks refuse; default MTU still works
    }
    for(var sub in _dataSubs) {
      await sub.cancel();
    }
    _dataSubs.clear();
    _control = null;

    List<BluetoothService> services = await _device.discoverServices();
    bool subscribed = false;
    for(BluetoothService s in services) {
      if(s.uuid == BleReceiver.adsbService) {
        // typed characteristics: one complete framed GDL90 message per
        // notification, safe to merge directly
        for(BluetoothCharacteristic c in s.characteristics) {
          if(c.uuid == BleReceiver.adsbTraffic ||
              c.uuid == BleReceiver.adsbOwnship ||
              c.uuid == BleReceiver.adsbStatus) {
            _dataSubs.add(c.onValueReceived.listen((data) {
              Storage().gdl90Buffer.put(Uint8List.fromList(data));
            }));
            await c.setNotifyValue(true);
            subscribed = true;
          }
          else if(c.uuid == BleReceiver.adsbUplink) {
            // FIS-B uplink frames exceed one notification; fragments carry a
            // 1-byte first/last/sequence header and reassemble per link
            _dataSubs.add(c.onValueReceived.listen(_uplinkReassembler.feed));
            await c.setNotifyValue(true);
          }
          else if(c.uuid == BleReceiver.adsbControl) {
            _control = c;
          }
        }
      }
    }
    if(!subscribed) {
      // fallback: UART byte stream; reassemble per link so frames from
      // multiple devices never interleave mid-frame
      for(BluetoothService s in services) {
        if(s.uuid == BleReceiver.nusService) {
          for(BluetoothCharacteristic c in s.characteristics) {
            if(c.uuid == BleReceiver.nusTx) {
              _dataSubs.add(c.onValueReceived.listen(_framer.feed));
              await c.setNotifyValue(true);
              subscribed = true;
            }
            else if(c.uuid == BleReceiver.nusRx) {
              _control = c;
            }
          }
        }
      }
    }
    if(!subscribed) {
      throw Exception("no ADS-B or UART service");
    }
  }

  Future<void> send(List<int> data) async {
    BluetoothCharacteristic? c = _control;
    if(c == null || !isConnected) {
      return;
    }
    try {
      await c.write(data, withoutResponse: c.properties.writeWithoutResponse);
    }
    catch(e) {
      AppLog.logMessage("BLE send failed ($name): $e");
    }
  }

  Future<void> stop() async {
    _running = false;
    for(var sub in _dataSubs) {
      await sub.cancel();
    }
    _dataSubs.clear();
    await _connectionSub?.cancel();
    _connectionSub = null;
    _control = null;
    try {
      await _device.disconnect();
    }
    catch(_) {}
    status.value = "Not connected";
  }
}

// Reassembles fragmented Uplink characteristic notifications (FIS-B) into
// complete framed GDL90 messages. Header byte: bit7 first, bit6 last,
// bits 0-5 sequence (mod 64); a sequence gap discards the partial message.
class UplinkReassembler {

  UplinkReassembler(this.onFrame);

  final void Function(Uint8List) onFrame;
  final List<int> _buffer = [];
  int _expectedSeq = -1; // -1: waiting for a first fragment

  void feed(List<int> data) {
    if(data.length < 2) {
      return;
    }
    int header = data[0];
    bool first = (header & 0x80) != 0;
    bool last = (header & 0x40) != 0;
    int seq = header & 0x3F;

    if(first) {
      _buffer.clear();
      _expectedSeq = seq;
    }
    if(_expectedSeq != seq) {
      _buffer.clear();
      _expectedSeq = -1; // lost a fragment; wait for the next first
      return;
    }
    _buffer.addAll(data.sublist(1));
    _expectedSeq = (seq + 1) & 0x3F;
    if(last) {
      onFrame(Uint8List.fromList(_buffer));
      _buffer.clear();
      _expectedSeq = -1;
    }
  }
}

// Reassembles a byte stream into complete GDL90 frames (0x7E ... 0x7E) and
// NMEA sentences ($ ... newline), forwarding only whole units so streams
// from multiple links can be merged safely.
class StreamFramer {

  StreamFramer(this.onGdl90Frame, this.onNmeaSentence);

  final void Function(Uint8List) onGdl90Frame;
  final void Function(Uint8List) onNmeaSentence;

  static const int _flag = 0x7E;
  static const int _maxBuffer = 8192;
  final List<int> _buffer = [];

  void feed(List<int> data) {
    _buffer.addAll(data);
    _extract();
    if(_buffer.length > _maxBuffer) {
      _buffer.clear(); // garbage in the stream; resync
    }
  }

  void _extract() {
    while(true) {
      // NMEA sentence at the head
      if(_buffer.isNotEmpty && (_buffer[0] == 0x24 || _buffer[0] == 0x21)) { // $ or !
        int nl = _buffer.indexOf(0x0A);
        if(nl < 0) {
          return; // incomplete
        }
        onNmeaSentence(Uint8List.fromList(_buffer.sublist(0, nl + 1)));
        _buffer.removeRange(0, nl + 1);
        continue;
      }
      // GDL90 frame at the head
      int start = _buffer.indexOf(_flag);
      if(start < 0) {
        _buffer.clear(); // noise between frames
        return;
      }
      if(start > 0) {
        _buffer.removeRange(0, start); // drop noise before the flag
      }
      // consume runs of adjacent flags (7E 7E frame separators)
      int skip = 1;
      while(skip < _buffer.length && _buffer[skip] == _flag) {
        skip++;
      }
      if(skip > 1) {
        _buffer.removeRange(0, skip - 1);
      }
      int close = _buffer.indexOf(_flag, 1);
      if(close < 0) {
        return; // incomplete frame
      }
      onGdl90Frame(Uint8List.fromList(_buffer.sublist(0, close + 1)));
      _buffer.removeRange(0, close + 1);
    }
  }
}
