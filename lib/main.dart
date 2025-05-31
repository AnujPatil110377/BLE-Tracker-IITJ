import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui'; // Required for DartPluginRegistrant
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Added

// MOVED TO TOP LEVEL and made accessible for background service
Map<String, dynamic>? parseFMDNData(ScanResult scanResult) {
  try {
    final serviceData = scanResult.advertisementData.serviceData;

    final fmdnKey = serviceData.keys.firstWhere(
        (uuid) => uuid.toString().toLowerCase().contains('feaa'),
        orElse: () => Guid('00000000-0000-0000-0000-000000000000'));

    if (fmdnKey.toString() == '00000000-0000-0000-0000-000000000000') {
      return null;
    }

    final data = serviceData[fmdnKey]!;
    if (data.length < 22) return null;

    final frameType = data[0];
    final eidBytes = data.sublist(1, 21);
    final flags = data[21];

    // Simplified logging for background to avoid too much noise
    // debugPrint("BG FMDN: ${scanResult.device.remoteId}, F:0x${frameType.toRadixString(16)}, EID:${eidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}");

    return {
      'frameType': frameType,
      'eid': eidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(''),
      'flags': flags,
    };
  } catch (e) {
    debugPrint(
        'Background parseFMDNData Error for ${scanResult.device.remoteId}: $e');
    return null;
  }
}

@pragma('vm:entry-point') // Mandatory for Android
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized(); 

  // Add a small delay to allow the isolate to fully initialize
  // before heavy plugin interaction. This is a common workaround for
  // "main isolate only" issues with background services.
  await Future.delayed(const Duration(milliseconds: 500));

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Timer? scanTimer;
  StreamSubscription<List<ScanResult>>? scanResultsSubscriptionBg;
  bool isCurrentlyScanningBg = false;
  int scanCycleCount = 0;

  // Initial notification
  if (Platform.isAndroid) {
    // Ensure this is called after the delay and plugin init
    flutterLocalNotificationsPlugin.show(
      888,
      'BLE Background Service',
      'Service initialized, waiting for first scan.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'ble_background_scan_channel',
          'BLE Background Scanning',
          channelDescription: 'Notification for background BLE scanning service.',
          icon: '@mipmap/ic_launcher',
          importance: Importance.low,
        ),
      ),
    );
  }


  Future<void> performBackgroundScan() async {
    if (isCurrentlyScanningBg) {
      debugPrint("BackgroundService: Scan already in progress.");
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      debugPrint("BackgroundService: Bluetooth is OFF.");
      if (Platform.isAndroid) {
        flutterLocalNotificationsPlugin.show(
          888, // Notification ID
          'BLE Background Scan Paused',
          'Bluetooth is off. Last check: ${DateTime.now().toShortTimeString()}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'ble_background_scan_channel', // Channel ID
              'BLE Background Scanning', // Channel Name
              channelDescription: 'Notification for background BLE scanning service.',
              icon: '@mipmap/ic_launcher', // make sure you have this icon
              importance: Importance.low,
            ),
          ),
        );
      }
      return;
    }

    scanCycleCount++;
    debugPrint("BackgroundService: Starting scan cycle #$scanCycleCount.");
    isCurrentlyScanningBg = true;

    if (Platform.isAndroid) {
       flutterLocalNotificationsPlugin.show(
        888,
        'BLE Background Scan Active',
        'Scanning cycle #$scanCycleCount started at ${DateTime.now().toShortTimeString()}',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'ble_background_scan_channel',
            'BLE Background Scanning',
            channelDescription: 'Notification for background BLE scanning service.',
            icon: '@mipmap/ic_launcher',
            importance: Importance.low,
            ongoing: true, // Make it persistent while scanning
          ),
        ),
      );
    }


    try {
      final List<String> foundDevicesInCycle = [];
      scanResultsSubscriptionBg = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          final fmdnData = parseFMDNData(r);
          if (fmdnData != null) {
            if (!foundDevicesInCycle.contains(r.device.remoteId.toString())) {
              debugPrint(
                  "BackgroundService: Found FMDN Device: ${r.device.remoteId}, Data: $fmdnData");
              foundDevicesInCycle.add(r.device.remoteId.toString());
              // service.invoke('foundDevice', {'device': r.device.remoteId.toString(), 'fmdn': fmdnData});
            }
          }
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 25), // Scan for 25 seconds
        androidScanMode: AndroidScanMode.lowPower,
      );
      
      // Wait for scan to complete (timeout duration + a small buffer)
      await Future.delayed(const Duration(seconds: 26));
      debugPrint("BackgroundService: Scan cycle #$scanCycleCount finished. Found ${foundDevicesInCycle.length} new FMDN devices.");

    } catch (e) {
      debugPrint("BackgroundService: Error during scan cycle #$scanCycleCount: $e");
    } finally {
      await scanResultsSubscriptionBg?.cancel();
      scanResultsSubscriptionBg = null;
      isCurrentlyScanningBg = false;
      // Ensure scan is stopped if it didn't timeout correctly or an error occurred
      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
        debugPrint("BackgroundService: Forcibly stopped scan post-cycle.");
      }
       if (Platform.isAndroid) {
         flutterLocalNotificationsPlugin.show(
            888,
            'BLE Background Scan Idle',
            'Last scan cycle #$scanCycleCount finished. Next scan soon.',
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'ble_background_scan_channel',
                'BLE Background Scanning',
                channelDescription: 'Notification for background BLE scanning service.',
                icon: '@mipmap/ic_launcher',
                importance: Importance.low,
              ),
            ),
          );
       }
    }
  }

  // Perform an initial scan shortly after service start if needed
  // Future.delayed(const Duration(seconds: 5), () async {
  //   if (!isCurrentlyScanningBg) await performBackgroundScan();
  // });
  
  // Start the first scan attempt shortly after the service and timer are ready
  // This replaces the immediate Future.delayed call that was commented out
  if (!isCurrentlyScanningBg) {
    // Adding a slight delay before the first scan as well
    Future.delayed(const Duration(seconds: 2), () async {
        if (!isCurrentlyScanningBg) { // Re-check in case stopService was called
            await performBackgroundScan();
        }
    });
  }

  scanTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
    debugPrint("BackgroundService: Timer ticked for new scan cycle.");
    if (!isCurrentlyScanningBg) {
      await performBackgroundScan();
    } else {
      debugPrint("BackgroundService: Skipping scan as one is already in progress.");
    }
  });

  service.on('stopService').listen((event) async {
    debugPrint("BackgroundService: Received stopService event.");
    scanTimer?.cancel();
    await scanResultsSubscriptionBg?.cancel();
    if (isCurrentlyScanningBg || await FlutterBluePlus.isScanning.first) {
      await FlutterBluePlus.stopScan();
    }
    await service.stopSelf();
    debugPrint("BackgroundService: Service stopped.");
  });
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  debugPrint('FLUTTER BACKGROUND SERVICE: iOS Background Fetch');
  // You could trigger a short scan here if needed and allowed by iOS policies
  return true;
}

// Helper for time formatting in notification
extension DateTimeFormatting on DateTime {
  String toShortTimeString() {
    final hour = this.hour.toString().padLeft(2, '0');
    final minute = this.minute.toString().padLeft(2, '0');
    final second = this.second.toString().padLeft(2, '0');
    return "$hour:$minute:$second";
  }
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'ble_background_scan_channel', // id
    'BLE Background Scanning', // title
    description: 'This channel is used for background BLE scanning notifications.',
    importance: Importance.low, // importance must be at low or higher level
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }
  
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      iOS: DarwinInitializationSettings(), // Basic iOS initialization
      android: AndroidInitializationSettings('@mipmap/ic_launcher'), // Default icon
    ),
  );


  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // CHANGED FROM true
      isForegroundMode: true,
      notificationChannelId: 'ble_background_scan_channel', // Must match channel ID
      initialNotificationTitle: 'BLE Scanner Service',
      initialNotificationContent: 'Initializing background scanning...',
      foregroundServiceNotificationId: 888, // Must match ID used in onStart
      foregroundServiceTypes: [ // Ensure this is a List
        AndroidForegroundType.location, 
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false, // CHANGED FROM true
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Request permissions
  if (Platform.isAndroid) {
    await Permission.location.request(); // General location
    await Permission.locationAlways.request(); // Background location
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.notification.request(); // For Android 13+ notifications
    // Optional: await Permission.ignoreBatteryOptimizations.request();
  } else if (Platform.isIOS) {
    await Permission.locationWhenInUse.request(); // or locationAlways
    await Permission.bluetooth.request();
  }
  
  await initializeService(); // Initialize background service
  
  runApp(const BLEScannerApp());
}

class BLEScannerApp extends StatelessWidget {
  const BLEScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE FMDN Scanner',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple, // Using colorSchemeSeed for M3
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  late StreamSubscription<BluetoothAdapterState> _adapterStateStateSubscription;

  final List<Map<String, dynamic>> _processedScanResults = []; // For foreground scan
  bool _isScanning = false; // For foreground manual scan
  late StreamSubscription<List<ScanResult>> _scanResultsSubscription;
  late StreamSubscription<bool> _isScanningSubscription;

  bool _isBackgroundServiceRunning = false;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndInitBluetooth(); 
    _checkBackgroundServiceStatus().then((_) {
      if (mounted && !_isBackgroundServiceRunning) {
        // If service is not running, try to start it after a brief delay
        // This ensures the UI is ready and might avoid the main isolate error
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && !_isBackgroundServiceRunning) {
            debugPrint("UI: Auto-attempting to start background service on init.");
            // Check permissions again before attempting to start
            _checkAndStartBackgroundService();
          }
        });
      }
    });

    _adapterStateStateSubscription =
        FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _adapterState = state);
      if (state == BluetoothAdapterState.off && _isBackgroundServiceRunning) {
        _showErrorSnackbar("Bluetooth turned off, background scan may be paused.");
      }
    });

    // Listener for FOREGROUND scan results
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (!_isScanning) return; // Only process if foreground scan is active

      List<Map<String, dynamic>> newProcessedResults = [];
      for (ScanResult r in results) {
        final fmdnData = parseFMDNData(r);
        if (fmdnData != null) {
          newProcessedResults.add({'result': r, 'fmdn': fmdnData});
        }
      }
      if (mounted) {
        setState(() {
          _processedScanResults.clear();
          _processedScanResults.addAll(newProcessedResults);
        });
      }
    }, onError: (e) => debugPrint('Foreground Scan error: $e'));

    // Listener for global scanning state (can be foreground or background)
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((state) {
      // This state reflects if ANY scan is happening.
      // We manage `_isScanning` specifically for the manual foreground scan button.
      if (mounted && !_isBackgroundServiceRunning && _isScanning != state) {
         // If background service is not running, this state directly reflects manual scan
         // setState(() => _isScanning = state); // Let _toggleScan manage this for manual scans
      }
    });

    // Optional: Listen for data from background service if needed in UI
    // FlutterBackgroundService().on('foundDevice').listen((event) { ... });
  }

  Future<void> _checkBackgroundServiceStatus() async {
    bool isRunning = await FlutterBackgroundService().isRunning();
    if (mounted) {
      setState(() {
        _isBackgroundServiceRunning = isRunning;
      });
    }
  }

  Future<void> _checkAndStartBackgroundService() async {
    // This is a helper to be called from initState or button press
    bool permissionsGranted = false;
    if (Platform.isAndroid) {
      permissionsGranted = await Permission.notification.isGranted &&
                           await Permission.locationAlways.isGranted &&
                           await Permission.bluetoothScan.isGranted &&
                           await Permission.bluetoothConnect.isGranted;
    } else if (Platform.isIOS) {
      permissionsGranted = await Permission.bluetooth.isGranted &&
                           (await Permission.locationWhenInUse.isGranted || await Permission.locationAlways.isGranted);
    }

    if (permissionsGranted) {
      final service = FlutterBackgroundService();
      await service.startService(); 
      debugPrint('UI: Background service auto-start invoked.');
      if (mounted) {
        setState(() {
          _isBackgroundServiceRunning = true;
        });
      }
    } else {
      debugPrint('UI: Auto-start of background service skipped due to missing permissions.');
      _showErrorSnackbar(
          'Background permissions not granted. Please enable them in app settings to start background service.');
    }
  }

  Future<void> _toggleBackgroundService() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke("stopService");
      debugPrint('UI: Background service stop invoked.');
    } else {
      // Re-check critical permissions before starting
      bool permissionsGranted = false;
      if (Platform.isAndroid) {
        permissionsGranted = await Permission.notification.isGranted &&
                             await Permission.locationAlways.isGranted &&
                             await Permission.bluetoothScan.isGranted &&
                             await Permission.bluetoothConnect.isGranted;
      } else if (Platform.isIOS) {
        permissionsGranted = await Permission.bluetooth.isGranted &&
                             (await Permission.locationWhenInUse.isGranted || await Permission.locationAlways.isGranted);
      }

      if (permissionsGranted) {
        await service.startService(); // Ensure this is startService()
        debugPrint('UI: Background service start invoked by toggle.');
      } else {
        _showErrorSnackbar(
            'Background permissions not granted. Please check app settings.');
        return; 
      }
    }
     if (mounted) {
      setState(() {
        _isBackgroundServiceRunning = !isRunning;
      });
    }
  }

  Future<void> _toggleScan() async { // Manual FOREGROUND scan
    if (!mounted) return;

    if (_adapterState != BluetoothAdapterState.on) {
      _showErrorSnackbar('Bluetooth is not enabled');
      return;
    }

    // Optional: Prevent manual scan if background scan is very active,
    // or just let them run concurrently if flutter_blue_plus handles it well.
    // if (_isBackgroundServiceRunning) {
    //   _showInfoSnackbar('Background scan is active. Manual scan will run concurrently.');
    // }

    bool currentSystemScanState = await FlutterBluePlus.isScanning.first;

    if (_isScanning) { // If UI thinks it's scanning (manual scan)
      try {
        await FlutterBluePlus.stopScan();
        debugPrint('Manual scan stopped by toggle.');
        if(mounted) setState(() => _isScanning = false);
      } catch (e) {
        _showErrorSnackbar('Error stopping manual scan: $e');
        if(mounted) setState(() => _isScanning = false); // ensure UI updates
      }
    } else { // If UI thinks it's not scanning (manual scan)
      if (currentSystemScanState && !_isBackgroundServiceRunning) {
        // If system is scanning but it's not our background service,
        // it might be a leftover scan. Try to stop it first.
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 200)); // give it a moment
      }
      if (mounted) {
        setState(() {
          _processedScanResults.clear();
          _isScanning = true;
        });
      }
      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 30), // Manual scan timeout
        );
        debugPrint('Manual scan started');
        // After timeout, flutter_blue_plus should stop scanning.
        // The _isScanningSubscription should update _isScanning,
        // but as a fallback:
        Future.delayed(const Duration(seconds: 31), () {
          if (mounted && _isScanning) {
             FlutterBluePlus.isScanning.first.then((isStillScanning) {
               if (mounted && _isScanning && !isStillScanning) {
                 setState(() => _isScanning = false);
               }
             });
          }
        });
      } catch (e) {
        _showErrorSnackbar('Error starting manual scan: $e');
        if(mounted) setState(() => _isScanning = false);
      }
    }
  }

  @override
  void dispose() {
    _adapterStateStateSubscription.cancel();
    _scanResultsSubscription.cancel();
    _isScanningSubscription.cancel();
    if (FlutterBluePlus.isScanningNow) { // Check actual scanning state
      FlutterBluePlus.stopScan();
    }
    super.dispose();
  }

  Future<void> _checkPermissionsAndInitBluetooth() async {
    // This handles foreground permissions. Background perms are in main/initializeService.
    // No changes needed here unless foreground logic changes.
    Map<Permission, PermissionStatus> statuses = {};
    if (Platform.isAndroid) {
      statuses = await [
        Permission.location, 
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    } else if (Platform.isIOS) {
      statuses[Permission.bluetooth] = await Permission.bluetooth.request();
      statuses[Permission.locationWhenInUse] = await Permission.locationWhenInUse.request();
    }

    bool allGranted = true;
    statuses.forEach((permission, status) {
      if (!status.isGranted) {
        allGranted = false;
        debugPrint("Foreground Permission denied: ${permission.toString()}");
      }
    });

    if (!allGranted) {
      _showErrorSnackbar('Required foreground permissions were not granted.');
    }
    
    if (await FlutterBluePlus.isSupported == false) {
        _showErrorSnackbar("Bluetooth not supported by this device");
        return;
    }

    _adapterState = await FlutterBluePlus.adapterState.first;
    if (mounted) setState(() {});
  }

  void _showErrorSnackbar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
   void _showInfoSnackbar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.blueAccent,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }


  Widget _buildDeviceList() {
    if (_adapterState != BluetoothAdapterState.on) {
      return const Center(
        child: Text('Bluetooth is OFF', 
          style: TextStyle(fontSize: 18, color: Colors.red)
        )
      );
    }

    if (_processedScanResults.isEmpty) {
      return Center(
        child: Text(
          _isScanning // This refers to foreground manual scan
            ? 'Scanning for devices (manual)...'
            : _isBackgroundServiceRunning 
              ? 'Background scan active.\nPress START SCAN for manual foreground scan.'
              : 'Press START SCAN for manual scan.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18),
        ),
      );
    }
    return ListView.builder(
      itemCount: _processedScanResults.length,
      itemBuilder: (context, index) {
        final Map<String, dynamic> result = _processedScanResults[index];
        final ScanResult scanResult = result['result'] as ScanResult;
        final Map<String, dynamic> fmdnData = result['fmdn'] as Map<String, dynamic>;

        String deviceName = scanResult.device.platformName.isNotEmpty 
            ? scanResult.device.platformName 
            : 'Unknown Device';

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            title: Text(deviceName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('RSSI: ${scanResult.rssi} dBm',
                  style: const TextStyle(fontFamily: 'monospace')),
                Text('Frame: 0x${fmdnData['frameType'].toRadixString(16).padLeft(2, '0')}',
                  style: const TextStyle(fontFamily: 'monospace')),
                SelectableText('EID: ${fmdnData['eid']}',
                  style: const TextStyle(fontFamily: 'monospace')),
                Text('Flags: 0x${fmdnData['flags'].toRadixString(16).padLeft(2, '0')}',
                  style: const TextStyle(fontFamily: 'monospace')),
              ],
            ),
            isThreeLine: true,
          ),
        );
      },
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Bluetooth: ${_adapterState.toString().split('.').last.toUpperCase()}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _adapterState == BluetoothAdapterState.on 
                          ? Colors.green.shade700 
                          : Colors.red.shade700,
                      ),
                    ),
                    if (_isScanning) // Indicator for manual foreground scan
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                     Text(
                      'Background Scan:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    ElevatedButton.icon(
                      icon: Icon(_isBackgroundServiceRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                      onPressed: _toggleBackgroundService,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isBackgroundServiceRunning ? Colors.orangeAccent : Colors.lightGreenAccent.shade700,
                        foregroundColor: _isBackgroundServiceRunning ? Colors.black : Colors.white,
                      ),
                      label: Text(_isBackgroundServiceRunning ? 'Stop BG' : 'Start BG'),
                    ),
                  ],
                ),
                 if (_isBackgroundServiceRunning)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Service is active in background.',
                      style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildDeviceList()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'manual_scan_fab',
        onPressed: (_adapterState == BluetoothAdapterState.on) ? _toggleScan : null,
        label: Text(
          _isScanning ? 'STOP SCAN' : 'START SCAN', // For manual foreground scan
        ),
        icon: Icon(
          _isScanning ? Icons.stop : Icons.search,
        ),
        backgroundColor: _isScanning 
            ? Colors.redAccent 
            : (_adapterState == BluetoothAdapterState.on ? Theme.of(context).colorScheme.primary : Colors.grey),
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
 
  }
}
