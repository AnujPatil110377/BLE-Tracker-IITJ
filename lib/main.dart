import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui'; // Required for DartPluginRegistrant
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Added
import 'package:geolocator/geolocator.dart'; // Added for location fetching
import 'package:ble_beacon_tracker/screens/map_screen.dart'; // Added for map view

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


  // Helper function to get current location
  Future<Position?> getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint("BackgroundService: Location services are disabled.");
        return null;
      }

      // Permissions should have been granted by the main app.
      // For background, `locationAlways` is key on Android.
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        debugPrint("BackgroundService: Location permission denied. Cannot fetch location.");
        // Optionally, notify the user or log this more visibly if critical
        return null;
      }
      
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium, // Adjust as needed
        timeLimit: const Duration(seconds: 10), // Timeout for location fetch
      );
    } catch (e) {
      debugPrint("BackgroundService: Error getting location: $e");
      return null;
    }
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
      scanResultsSubscriptionBg = FlutterBluePlus.scanResults.listen((results) async { // Made callback async
        for (ScanResult r in results) {          final fmdnData = parseFMDNData(r);
          if (fmdnData != null) {
            if (!foundDevicesInCycle.contains(r.device.remoteId.toString())) {
              foundDevicesInCycle.add(r.device.remoteId.toString());
              
              String deviceName = r.device.platformName.isNotEmpty 
                  ? r.device.platformName 
                  : (r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : "Unknown Device");
              
              // Fetch location when a new FMDN device is found
              Position? currentLocation = await getCurrentLocation();
              
              // Log device discovery
              debugPrint(
                  "BackgroundService: Found FMDN Device: ID=${r.device.remoteId}, Name='$deviceName', RSSI=${r.rssi}, Data: $fmdnData");
              
              // If location available, log it and send to UI
              if (currentLocation != null) {
                debugPrint("BackgroundService: Location: Lat ${currentLocation.latitude.toStringAsFixed(5)}, " +
                    "Lon ${currentLocation.longitude.toStringAsFixed(5)} (Acc: ${currentLocation.accuracy.toStringAsFixed(1)}m)");
                
                // Send data to UI for map display
                service.invoke('foundDevice', {
                  'device': r.device.remoteId.toString(),
                  'name': deviceName,
                  'fmdn': fmdnData,
                  'rssi': r.rssi,
                  'location': {
                    'latitude': currentLocation.latitude,
                    'longitude': currentLocation.longitude,
                    'accuracy': currentLocation.accuracy,
                    'timestamp': DateTime.now().millisecondsSinceEpoch,
                  }
                });
              } else {
                debugPrint("BackgroundService: Location: Not available");
              }
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
  
  // Listen for ping test (for API testing)
  service.on('ping').listen((event) {
    debugPrint("BackgroundService: Received ping test. Responding...");
    service.invoke('pingResponse', {
      'success': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'original': event,
    });
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
    await Permission.locationAlways.request(); // Crucial for background location
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
    });    // Listen for data from background service for UI updates
    FlutterBackgroundService().on('foundDevice').listen((event) {
      if (mounted && event != null) {
        // Print detailed debug info
        debugPrint('🔍 UI: RECEIVED DEVICE: ${event['name'] ?? 'Unknown'} | ID: ${event['device']} | RSSI: ${event['rssi']}');
        if (event['location'] != null) {
          debugPrint('📍 LOCATION: Lat ${event['location']['latitude']}, Lng ${event['location']['longitude']}');
        }
        if (event['fmdn'] != null) {
          debugPrint('🔑 FMDN EID: ${event['fmdn']['eid']}');
        }
        
        // Show a snackbar when a device is found
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Found device: ${event['name'] ?? 'Unknown'}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: 'View on Map',
              textColor: Colors.white,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const MapScreen()),
                );
              },
            ),
          ),
        );
      }
    });
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

  @override
  void dispose() {
    _adapterStateStateSubscription.cancel();
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

  Widget _buildDeviceList() {
    if (_adapterState != BluetoothAdapterState.on) {
      return const Center(
        child: Text('Bluetooth is OFF', 
          style: TextStyle(fontSize: 18, color: Colors.red)
        )
      );
    }

    // Simplified: No longer displays foreground scan results or "Press START SCAN"
    return Center(
      child: Text(
        _isBackgroundServiceRunning 
          ? 'Background scanning is active.'
          : 'Background service is not running. Start it using the button below.',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18),
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(      appBar: AppBar(
        title: const Text('BLE Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // Test API button
          IconButton(
            icon: const Icon(Icons.api),
            tooltip: 'Test Service API',
            onPressed: _testBackgroundServiceCommunication,
          ),
          // Test button for API testing
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Simulate Device',
            onPressed: _simulateDeviceFound,
          ),
          // Map view button
          IconButton(
            icon: const Icon(Icons.map),
            tooltip: 'View Tracker Map',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const MapScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Text(
                  'Adapter State: ${_adapterState.toString().split('.').last}',
                  style: TextStyle(
                      fontSize: 16,
                      color: _adapterState == BluetoothAdapterState.on
                          ? Colors.green
                          : Colors.red),
                ),
                const SizedBox(height: 8),
                Text(
                  'Background Service: ${_isBackgroundServiceRunning ? "Running" : "Stopped"}',
                  style: TextStyle(
                      fontSize: 16,
                      color: _isBackgroundServiceRunning
                          ? Colors.green
                          : Colors.orange),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(child: _buildDeviceList()), // This now shows status text
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleBackgroundService,
        label: Text(_isBackgroundServiceRunning ? 'Stop Background Service' : 'Start Background Service'),
        icon: Icon(_isBackgroundServiceRunning ? Icons.stop : Icons.play_arrow),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
  // DEBUG METHOD: Simulate finding a device for testing
  Future<void> _simulateDeviceFound() async {
    try {
      // Get current location
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      
      // Create a simulated device event
      final event = {
        'device': 'simulated-device-${DateTime.now().millisecondsSinceEpoch}',
        'name': 'Test Device',
        'fmdn': {
          'frameType': 0,
          'eid': 'simulated-eid-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}',
          'flags': 0,
        },
        'rssi': -65,
        'location': {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }
      };
      
      // Log the simulated event
      debugPrint('📱 SIMULATING DEVICE: ${event['name']} at ${position.latitude}, ${position.longitude}');
      
      // Send to the service to broadcast (this will trigger the UI listeners)
      final service = FlutterBackgroundService();
      service.invoke('foundDevice', event);
    } catch (e) {
      debugPrint('❌ Error simulating device: $e');
    }
  }  // Test if background service communication is working
  Future<void> _testBackgroundServiceCommunication() async {
    if (!_isBackgroundServiceRunning) {
      _showErrorSnackbar('Background service is not running. Start it first.');
      return;
    }
    
    final service = FlutterBackgroundService();
    
    // Register temporary listener to get confirmation
    bool gotResponse = false;
    late StreamSubscription subscription;
    
    debugPrint('🧪 Testing background service communication...');
    
    // Create a one-time listener for the ping response
    subscription = service.on('pingResponse').listen((event) {
      debugPrint('✅ Received ping response from background service: $event');
      gotResponse = true;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Background service communication is working! ✅'),
            backgroundColor: Colors.green,
          ),
        );
      }
      
      subscription.cancel();
    });
    
    // Send the ping
    service.invoke('ping', {'timestamp': DateTime.now().millisecondsSinceEpoch});
    
    // Give it a moment to respond
    await Future.delayed(const Duration(seconds: 2));
    
    if (!gotResponse) {
      debugPrint('❌ No ping response received from background service');
      if (mounted) {
        _showErrorSnackbar('No response from background service. Communication may be broken.');
      }
      subscription.cancel();
    }
  }
}
