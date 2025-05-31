import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BeaconScanTaskHandler());
}

class BeaconScanTaskHandler extends TaskHandler {
  static const String tag = "BeaconScanTask";
  static const scanDuration = Duration(minutes: 4);
  static const scanInterval = Duration(minutes: 5);
  
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  bool _isScanning = false;
  SharedPreferences? _prefs;
  Timer? _scanTimer;
  DateTime? _lastScanStart;
  
  BeaconScanTaskHandler() {
    _setupNotifications();
  }

  Future<void> _setupNotifications() async {
    final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await notifications.initialize(initSettings);
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    
    try {
      _lastScanStart = DateTime.now();
      await FlutterBluePlus.startScan(
        timeout: scanDuration,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      _isScanning = true;
      debugPrint('$tag: Started BLE scan');

      _scanTimer?.cancel();
      _scanTimer = Timer(scanInterval, () {
        if (!_isScanning) {
          _startScan();
        }
      });
    } catch (e) {
      debugPrint('$tag: Scan error - $e');
      _isScanning = false;
    }
  }

  Future<void> _showNotification(String title, String body) async {
    final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();
    const androidDetails = AndroidNotificationDetails(
      'ble_scan_channel',
      'BLE Scanner',
      channelDescription: 'Background BLE scanning notifications',
      importance: Importance.low,
      priority: Priority.low,
      showWhen: false,
    );
    const notificationDetails = NotificationDetails(android: androidDetails);
    await notifications.show(0, title, body, notificationDetails);
  }

  Map<String, dynamic>? _parseFMDNData(ScanResult result) {
    final serviceData = result.advertisementData.serviceData;
    final fmdnKey = serviceData.keys.firstWhere(
      (uuid) => uuid.toString().toLowerCase().contains('feaa'),
      orElse: () => Guid('00000000-0000-0000-0000-000000000000')
    );
              
    if (fmdnKey.toString() == '00000000-0000-0000-0000-000000000000') return null;

    final data = serviceData[fmdnKey]!;
    if (data.length < 22) return null;

    return {
      'frameType': data[0],
      'eid': data.sublist(1, 21).map((b) => b.toRadixString(16).padLeft(2, '0')).join(''),
      'flags': data[21],
    };
  }

  void _handleScanResult(ScanResult result) async {
    if (_prefs == null) {
      _prefs = await SharedPreferences.getInstance();
    }

    final fmdnData = _parseFMDNData(result);
    if (fmdnData == null) return;

    final deviceId = result.device.remoteId.toString();
    final timestamp = DateTime.now().toIso8601String();
    final data = {
      'deviceId': deviceId,
      'rssi': result.rssi,
      'timestamp': timestamp,
      'data': fmdnData,
    };

    // Save scan result
    final jsonStr = jsonEncode(data);
    final key = 'scan_${deviceId}_$timestamp';
    await _prefs?.setString(key, jsonStr);

    // Update scan history
    final scanKeys = _prefs?.getStringList('all_scan_keys') ?? [];
    if (scanKeys.length > 1000) {
      final oldestKey = scanKeys.removeAt(0);
      await _prefs?.remove(oldestKey);
    }
    scanKeys.add(key);
    await _prefs?.setStringList('all_scan_keys', scanKeys);

    await _showNotification(
      'Found FMDN Device',
      'Device: $deviceId, RSSI: ${result.rssi}dBm'
    );
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('$tag: Starting background service');

    _adapterStateSub = FlutterBluePlus.adapterState.listen(
      (state) {
        if (state == BluetoothAdapterState.on && !_isScanning) {
          _startScan();
        } else if (state != BluetoothAdapterState.on) {
          _isScanning = false;
        }
      },
      onError: (e) => debugPrint('$tag: Adapter state error - $e'),
    );

    _scanResultsSub = FlutterBluePlus.scanResults.listen(
      (results) {
        for (final r in results) {
          _handleScanResult(r);
        }
      },
      onError: (e) => debugPrint('$tag: Scan results error - $e'),
    );

    if (await FlutterBluePlus.isSupported) {
      final state = await FlutterBluePlus.adapterState.first;
      if (state == BluetoothAdapterState.on) {
        await _startScan();
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isForeground) async {
    debugPrint('$tag: Stopping background service');
    _isScanning = false;
    _scanTimer?.cancel();
    await FlutterBluePlus.stopScan();
    await _scanResultsSub?.cancel();
    await _adapterStateSub?.cancel();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (!_isScanning) {
      _startScan();
    }
  }
}
