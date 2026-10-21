import 'dart:async';
import 'package:avaremp/io/softrf_config.dart';
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

  // HM-10 style serial service (SoftRF nRF52 "serial port emulation" sends
  // its NMEA/GDL90 stream here, not on the Nordic UART it also exposes)
  static final Guid hm10Service = Guid("0000FFE0-0000-1000-8000-00805F9B34FB");
  static final Guid hm10Data = Guid("0000FFE1-0000-1000-8000-00805F9B34FB"); // notify + write

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  final Map<String, BleLink> _links = {};
  final ValueNotifier<int> change = ValueNotifier(0); // links added/removed/status
  final ValueNotifier<bool> scanning = ValueNotifier(false);

  List<BleLink> get links => _links.values.toList();
  bool get anyConnected => _links.values.any((l) => l.isConnected);

  // last scan error, surfaced in the UI (Android can fail silently on
  // permissions otherwise)
  final ValueNotifier<String> scanError = ValueNotifier("");

  // true if a scan result looks like an ADS-B receiver: advertises the ADSB
  // or UART service, or carries a known receiver name. Scanning runs
  // unfiltered and matches client-side - Android's firmware-level service
  // filters miss some advertisers.
  static bool isReceiver(ScanResult r) {
    for(Guid uuid in r.advertisementData.serviceUuids) {
      if(uuid == adsbService || uuid == nusService || uuid == hm10Service) {
        return true;
      }
    }
    String name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return RegExp(r'adsbee|softrf|stratux|x1-gdl90', caseSensitive: false).hasMatch(name);
  }

  // scan for ADS-B receivers; results stream in FlutterBluePlus.scanResults,
  // filter with isReceiver()
  Future<void> scan() async {
    if(!supported || scanning.value) {
      return;
    }
    try {
      scanning.value = true;
      scanError.value = "";
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
    }
    catch(e) {
      AppLog.logMessage("BLE scan failed: $e");
      scanError.value = "Scan failed: $e";
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
  // when the last byte arrived on this link (0 = never); the receiver row
  // shows its age so "connected but silent" is visible at a glance
  int lastDataMs = 0;
  Timer? _ageTimer;

  void _onFrame(Uint8List frame) {
    lastDataMs = DateTime.now().millisecondsSinceEpoch;
    Storage().receptionLogger.onFrame(name, frame);
    Storage().gdl90Buffer.put(frame);
  }

  late final StreamFramer _framer = StreamFramer(_onFrame, _onNmea);
  late final StreamFramer _hm10Framer = StreamFramer(_onFrame, _onNmea);

  /// "2 s ago" / "no data for 40 s" / "" when nothing has arrived yet
  String get dataAge {
    if(lastDataMs == 0) {
      return isConnected ? "no data yet" : "";
    }
    final int s = (DateTime.now().millisecondsSinceEpoch - lastDataMs) ~/ 1000;
    return s < 10 ? "data ${s}s ago" : "no data for ${s}s";
  }

  // SoftRF configuration as last reported by the unit ("" until queried)
  final ValueNotifier<String> softRfInfo = ValueNotifier("");
  int? softRfAddress;
  bool? softRfMux;
  // settings sentence to send once the unit comes back from the restart
  // that the address sentence triggers
  String? _pendingSettings;

  // units that take the $PSRFA/$PSRFC configuration sentences: SoftRF
  // (serial emulation, restarts on store) and x1-gdl90 (ADSBee service,
  // applies live and answers on the Status characteristic)
  bool get isSoftRf => name.toLowerCase().startsWith("softrf") ||
      name.toLowerCase().startsWith("x1-gdl90");
  bool _typedService = false; // connected through the ADSBee GATT service

  // settings replies are consumed here; everything else is receiver data
  void _onNmea(Uint8List sentence) {
    lastDataMs = DateTime.now().millisecondsSinceEpoch;
    final String s = String.fromCharCodes(sentence);
    if(s.startsWith("\$PSRFA,") || s.startsWith("\$PSRFC,")) {
      final int? addr = SoftRfConfig.parseAddressReply(s);
      if(addr != null) {
        softRfAddress = addr;
        softRfMux = SoftRfConfig.parseMuxReply(s);
      }
      final String? cfg = SoftRfConfig.describeSettingsReply(s);
      final String a = softRfAddress == null ? ""
          : "ID ${softRfAddress!.toRadixString(16).toUpperCase().padLeft(6, '0')}"
            "${softRfMux == true ? " + 1090 mux" : ""}";
      softRfInfo.value = [a, if(cfg != null) cfg].where((e) => e.isNotEmpty).join(" \u00b7 ");
      return;
    }
    Storage().nmeaBuffer.put(sentence);
  }

  // ask a SoftRF unit for its address and settings (replies arrive via _onNmea)
  Future<void> querySoftRf() async {
    await send(SoftRfConfig.queryAddress().codeUnits);
    await send(SoftRfConfig.querySettings().codeUnits);
  }

  // set the aircraft address (the unit stores it and restarts), then send
  // the traffic-link settings when the link comes back (second restart)
  Future<void> configureSoftRf({required int icao, required int protocol, bool mux = false}) async {
    if(_typedService) {
      // x1-gdl90 applies live: send both now and re-query
      await send(SoftRfConfig.setAddress(icao, mux: mux).codeUnits);
      await Future.delayed(const Duration(milliseconds: 300));
      await send(SoftRfConfig.settings(protocol: protocol).codeUnits);
      await Future.delayed(const Duration(milliseconds: 300));
      await querySoftRf();
      return;
    }
    _pendingSettings = SoftRfConfig.settings(protocol: protocol);
    await send(SoftRfConfig.setAddress(icao, mux: mux).codeUnits);
    softRfInfo.value = "Address sent, unit restarting\u2026";
  }
  late final UplinkReassembler _uplinkReassembler = UplinkReassembler(_onFrame);
  bool _running = false;

  String get id => _device.remoteId.str;
  String get name =>
      _device.platformName.isEmpty ? _device.remoteId.str : _device.platformName;
  bool get isConnected => _device.isConnected;

  Future<void> start() async {
    _running = true;
    _ageTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      // refresh the row (data age) and nudge a stalled reconnect: the OS
      // autoConnect usually brings the link back on its own, but a receiver
      // that rebooted mid-session has been seen to stay disconnected
      if(_running && !isConnected && lastDataMs != 0 &&
          DateTime.now().millisecondsSinceEpoch - lastDataMs > 15000) {
        _device.connect(autoConnect: true, mtu: null).catchError((_) {});
        lastDataMs = DateTime.now().millisecondsSinceEpoch - 5000; // retry again in ~10 s
      }
      _owner.change.value++;
    });
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
              lastDataMs = DateTime.now().millisecondsSinceEpoch;
              if(data.isNotEmpty && data[0] == 0x24) {
                _onNmea(Uint8List.fromList(data)); // "$...": a settings reply
                return;
              }
              Storage().receptionLogger.onFrame(name, data);
              Storage().gdl90Buffer.put(Uint8List.fromList(data));
            }));
            await c.setNotifyValue(true);
            subscribed = true;
            _typedService = true;
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
      // multiple devices never interleave mid-frame. A device may expose
      // both the Nordic UART and the HM-10 service (SoftRF does, and only
      // streams on HM-10), so subscribe to every serial characteristic
      // found, each with its own framer.
      for(BluetoothService s in services) {
        if(s.uuid == BleReceiver.nusService) {
          for(BluetoothCharacteristic c in s.characteristics) {
            if(c.uuid == BleReceiver.nusTx) {
              _dataSubs.add(c.onValueReceived.listen(_framer.feed));
              await c.setNotifyValue(true);
              subscribed = true;
            }
            else if(c.uuid == BleReceiver.nusRx) {
              _control ??= c;
            }
          }
        }
        else if(s.uuid == BleReceiver.hm10Service) {
          for(BluetoothCharacteristic c in s.characteristics) {
            if(c.uuid == BleReceiver.hm10Data) {
              _dataSubs.add(c.onValueReceived.listen(_hm10Framer.feed));
              await c.setNotifyValue(true);
              subscribed = true;
              _control = c; // SoftRF reads its serial input here, prefer it
            }
          }
        }
      }
    }
    if(!subscribed) {
      throw Exception("no ADS-B or UART service");
    }
    if(isSoftRf) {
      final String? pending = _pendingSettings;
      if(pending != null) {
        _pendingSettings = null;
        await Future.delayed(const Duration(seconds: 1)); // let the unit settle
        await send(pending.codeUnits);
        softRfInfo.value = "Settings sent, unit restarting\u2026";
        return; // query on the next reconnect
      }
      await querySoftRf();
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
    _ageTimer?.cancel();
    _ageTimer = null;
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
