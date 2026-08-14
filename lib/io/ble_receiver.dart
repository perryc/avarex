import 'dart:async';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:universal_io/io.dart';

// BLE ADS-B receiver client (ADSBee and similar open receivers).
//
// Primary interface is the ADS-B Receiver GATT service (see
// docs/BLE_ADSB_SERVICE.md): typed notify characteristics for traffic,
// ownship, and status. Each notification carries one complete framed GDL90
// message, so notifications are atomic (no stream reassembly) and the
// payloads remain standard GDL90 that any decoder understands. A Nordic
// UART Service fallback supports existing byte-stream devices (SoftRF,
// BLE-serial bridges), where data is treated as a raw GDL90/NMEA stream.
//
// Works on iOS/iPadOS as well as Android, and leaves Wi-Fi free for
// internet (phone hotspot).
class BleReceiver {

  // ADS-B Receiver Service ("0BEE"/"1090" - see docs/BLE_ADSB_SERVICE.md)
  static final Guid adsbService = Guid("0BEE0001-1090-46F0-A9AC-52D6BE4C29CC");
  static final Guid adsbTraffic = Guid("0BEE0010-1090-46F0-A9AC-52D6BE4C29CC"); // notify
  static final Guid adsbOwnship = Guid("0BEE0011-1090-46F0-A9AC-52D6BE4C29CC"); // notify
  static final Guid adsbStatus = Guid("0BEE0012-1090-46F0-A9AC-52D6BE4C29CC"); // notify
  static final Guid adsbControl = Guid("0BEE0020-1090-46F0-A9AC-52D6BE4C29CC"); // write

  // Nordic UART Service fallback (SoftRF, BLE-serial bridges)
  static final Guid nusService = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid nusTx = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"); // notify
  static final Guid nusRx = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); // write

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  final ValueNotifier<String> status = ValueNotifier("Not connected");
  final ValueNotifier<bool> scanning = ValueNotifier(false);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  final List<StreamSubscription<List<int>>> _dataSubs = [];
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  bool _running = false;

  String get connectedName => _device?.platformName ?? "";
  bool get isConnected => _device?.isConnected ?? false;

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
    Storage().settings.setBleDeviceId(device.remoteId.str);
    await _connectTo(device);
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    await disconnect(forget: false);
    _running = true;
    _device = device;
    status.value = "Connecting to ${device.platformName}";
    _connectionSub = device.connectionState.listen((state) async {
      if(state == BluetoothConnectionState.connected) {
        try {
          await _subscribe(device);
          status.value = "Connected to ${device.platformName}";
        }
        catch(e) {
          AppLog.logMessage("BLE subscribe failed: $e");
          status.value = "Error: $e";
        }
      }
      else if(state == BluetoothConnectionState.disconnected && _running) {
        status.value = "Reconnecting to ${device.platformName}";
      }
    });
    try {
      // autoConnect lets the OS re-establish the link whenever the receiver
      // powers up in range
      await device.connect(autoConnect: true, mtu: null);
    }
    catch(e) {
      AppLog.logMessage("BLE connect failed: $e");
      status.value = "Error: $e";
    }
  }

  void _feed(List<int> data) {
    Storage().gdl90Buffer.put(Uint8List.fromList(data));
    Storage().nmeaBuffer.put(Uint8List.fromList(data));
  }

  Future<void> _notifyOn(BluetoothCharacteristic c) async {
    _dataSubs.add(c.onValueReceived.listen(_feed));
    await c.setNotifyValue(true);
  }

  Future<void> _subscribe(BluetoothDevice device) async {
    if(Platform.isAndroid) {
      try {
        await device.requestMtu(247);
      }
      catch(_) {} // some stacks refuse; default MTU still works
    }
    for(var sub in _dataSubs) {
      await sub.cancel();
    }
    _dataSubs.clear();
    _control = null;

    List<BluetoothService> services = await device.discoverServices();
    bool subscribed = false;
    for(BluetoothService s in services) {
      if(s.uuid == adsbService) {
        // proper typed characteristics; one framed GDL90 message per notification
        for(BluetoothCharacteristic c in s.characteristics) {
          if(c.uuid == adsbTraffic || c.uuid == adsbOwnship || c.uuid == adsbStatus) {
            await _notifyOn(c);
            subscribed = true;
          }
          else if(c.uuid == adsbControl) {
            _control = c;
          }
        }
      }
    }
    if(!subscribed) {
      // fallback: UART byte stream devices
      for(BluetoothService s in services) {
        if(s.uuid == nusService) {
          for(BluetoothCharacteristic c in s.characteristics) {
            if(c.uuid == nusTx) {
              await _notifyOn(c);
              subscribed = true;
            }
            else if(c.uuid == nusRx) {
              _control = c;
            }
          }
        }
      }
    }
    if(!subscribed) {
      throw Exception("no ADS-B or UART service on device");
    }
  }

  // send to the device's control/RX characteristic (config, autopilot data)
  Future<void> send(List<int> data) async {
    BluetoothCharacteristic? c = _control;
    if(c == null || !isConnected) {
      return;
    }
    try {
      await c.write(data, withoutResponse: c.properties.writeWithoutResponse);
    }
    catch(e) {
      AppLog.logMessage("BLE send failed: $e");
    }
  }

  // reconnect to the remembered device (called from startIO)
  void startAutoConnect() {
    if(!supported) {
      return;
    }
    String id = Storage().settings.getBleDeviceId();
    if(id.isEmpty || _running) {
      return;
    }
    try {
      _connectTo(BluetoothDevice.fromId(id));
    }
    catch(e) {
      AppLog.logMessage("BLE auto-connect failed: $e");
    }
  }

  Future<void> disconnect({bool forget = true}) async {
    _running = false;
    if(forget) {
      Storage().settings.setBleDeviceId("");
    }
    for(var sub in _dataSubs) {
      await sub.cancel();
    }
    _dataSubs.clear();
    await _connectionSub?.cancel();
    _connectionSub = null;
    _control = null;
    try {
      await _device?.disconnect();
    }
    catch(_) {}
    _device = null;
    status.value = "Not connected";
  }
}
