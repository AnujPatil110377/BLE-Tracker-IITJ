import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'; // Added for permission checks

// Model for tracker data - can be expanded
class TrackerDevice {
  final String id;
  String name;
  String lastPing;
  String status;
  Color color;
  LatLng? lastLocation;
  DateTime? lastTimestamp;

  TrackerDevice({
    required this.id,
    required this.name,
    this.lastPing = "N/A",
    this.status = "Unknown",
    this.color = Colors.grey,
    this.lastLocation,
    this.lastTimestamp,
  });
}

class TrackerHomeScreen extends StatefulWidget {
  const TrackerHomeScreen({super.key});

  @override
  State<TrackerHomeScreen> createState() => _TrackerHomeScreenState();
}

class _TrackerHomeScreenState extends State<TrackerHomeScreen> {
  final Map<String, TrackerDevice> _trackers = {};
  bool _isBackgroundServiceRunning = false;
  GoogleMapController? _googleMapController;
  Set<Marker> _markers = {};
  Marker? _userMarker;
  Position? _currentUserPosition;
  late StreamSubscription<Position> _positionStreamSubscription;
  StreamSubscription? _foundDeviceSubscription;
  StreamSubscription? _pingResponseSubscription;
  bool _isLoadingLocation = true;
  bool _suppressAutoCamera = false; // Flag to suppress auto-zoom

  static const String _darkMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#746855"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},
    {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
    {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
    {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#263c3f"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9ca5b3"}]},
    {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#2f3948"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]}
  ]''';

  // New color palette
  static const Color _surfaceColor   = Color(0xFF1F1F1F);
  static const Color _accentGreen    = Color(0xFF34C759);
  static const Color _accentAqua     = Color(0xFF03DAC6);
  static const Color _primaryText    = Color(0xFFFFFFFF);
  static const Color _secondaryText  = Color(0xFFB3B3B3);

  @override
  void initState() {
    super.initState();
    _checkBackgroundServiceStatus();
    _initializeListeners();
    _determineUserPosition();
    // TODO: Call _checkAndStartBackgroundService if needed, or rely on autoStart
  }

  @override
  void dispose() {
    _googleMapController?.dispose();
    // Dispose any stream subscriptions
    _positionStreamSubscription?.cancel();
    _foundDeviceSubscription?.cancel();
    _pingResponseSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkBackgroundServiceStatus() async {
    bool isRunning = await FlutterBackgroundService().isRunning();
    if (mounted) {
      setState(() {
        _isBackgroundServiceRunning = isRunning;
      });
    }
  }

  void _initializeListeners() {
    _foundDeviceSubscription = FlutterBackgroundService().on('foundDevice').listen((event) {
      if (mounted && event != null) {
        final deviceId = event['device'] as String;
        final name = event['name'] as String? ?? 'Unknown Device';
        final fmdnData = event['fmdn'] as Map?;
        final eid = fmdnData?['eid'] as String? ?? 'N/A';
        final locationData = event['location'] as Map?;
        LatLng? newLocation;
        DateTime newTimestamp = DateTime.now();

        if (locationData != null) {
          newLocation = LatLng(
            locationData['latitude'] as double,
            locationData['longitude'] as double,
          );
          if (locationData['timestamp'] != null) {
            newTimestamp = DateTime.fromMillisecondsSinceEpoch(locationData['timestamp'] as int);
          }
        }
        
        debugPrint('TRACKER HOME UI: Received device $name ($deviceId) at $newLocation');

        setState(() {
          _trackers.update(
            deviceId,
            (existing) {
              existing.name = name; // Update name in case it changes
              existing.lastLocation = newLocation ?? existing.lastLocation;
              existing.lastTimestamp = newTimestamp;
              existing.lastPing = _formatTimestamp(newTimestamp);
              existing.status = "Active"; // Assuming active if recently found
              existing.color = _accentGreen;     // use new accent green
              return existing;
            },
            ifAbsent: () => TrackerDevice(
              id: deviceId,
              name: name,
              lastLocation: newLocation,
              lastTimestamp: newTimestamp,
              lastPing: _formatTimestamp(newTimestamp),
              status: "Active",
              color: _accentGreen,               // use new accent green
            ),
          );
          _updateMarkersAndCamera();
        });
      }
    });
     // Listen for ping response (optional, for testing)
     _pingResponseSubscription = FlutterBackgroundService().on('pingResponse').listen((event) {
      if (mounted) {
        debugPrint('TRACKER HOME UI: Ping response $event');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ping response: ${event?['success'] == true ? "OK" : "Failed"}'),
            backgroundColor: event?['success'] == true ? Colors.green : Colors.red,
          ),
        );
      }
    });
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return "N/A";
    final duration = DateTime.now().difference(timestamp);
    if (duration.inSeconds < 60) return "${duration.inSeconds}s ago";
    if (duration.inMinutes < 60) return "${duration.inMinutes}m ago";
    if (duration.inHours < 24) return "${duration.inHours}h ago";
    return "${duration.inDays}d ago";
  }

  Future<void> _determineUserPosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Handle service disabled
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Handle permission denied
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Handle permission permanently denied
      return;
    }

    try {
      Position position = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() {
          _currentUserPosition = position;
          _updateUserMarker();
          if (_googleMapController != null && _trackers.isEmpty) { // Center on user if no trackers yet
             _googleMapController!.animateCamera(
              CameraUpdate.newLatLngZoom(LatLng(position.latitude, position.longitude), 15.0),
            );
          }
        });
      }
    } catch (e) {
      debugPrint("Error getting current location for map: $e");
    }
     _positionStreamSubscription = Geolocator.getPositionStream().listen((Position position) {
      if (mounted) {
        setState(() {
          _currentUserPosition = position;
          _updateUserMarker();
        });
      }
    });
  }

  void _updateUserMarker() {
    if (_currentUserPosition != null) {
      final userLatLng = LatLng(_currentUserPosition!.latitude, _currentUserPosition!.longitude);
      _userMarker = Marker(
        markerId: const MarkerId('user_location'),
        position: userLatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'My Location'),
      );
      _updateMarkersAndCamera(); // Rebuild all markers
    }
  }
  
  void _updateMarkersAndCamera() {
    Set<Marker> newMarkers = {};
    if (_userMarker != null) {
      newMarkers.add(_userMarker!);
    }

    List<LatLng> allPoints = [];
    if (_currentUserPosition != null) {
      allPoints.add(LatLng(_currentUserPosition!.latitude, _currentUserPosition!.longitude));
    }

    _trackers.forEach((id, tracker) {
      if (tracker.lastLocation != null) {
        newMarkers.add(
          Marker(
            markerId: MarkerId(id),
            position: tracker.lastLocation!,
            infoWindow: InfoWindow(title: tracker.name, snippet: 'Status: ${tracker.status}'),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              tracker.status == "Active" ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueOrange,
            ),
          ),
        );
        allPoints.add(tracker.lastLocation!);
      }
    });

    setState(() {
      _markers = newMarkers;
    });
  }

  Future<void> _toggleBackgroundService() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke("stopService");
      debugPrint('TRACKER HOME UI: Background service stop invoked.');
    } else {
      // Permissions should have been granted at app start.
      // If not, this won't work as expected. Consider re-checking or guiding user.
      await service.startService();
      debugPrint('TRACKER HOME UI: Background service start invoked by toggle.');
    }
    if (mounted) {
      setState(() {
        _isBackgroundServiceRunning = !isRunning;
      });
    }
  }
  
  // Method to test service communication (can be linked to a debug button if needed)
  Future<void> _testBackgroundServiceCommunication() async {
    if (!_isBackgroundServiceRunning) {
       if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Background service is not running. Start it first.'), backgroundColor: Colors.orange),
        );
      }
      return;
    }
    final service = FlutterBackgroundService();
    debugPrint('TRACKER HOME UI: Sending ping to background service...');
    service.invoke('ping', {'timestamp': DateTime.now().millisecondsSinceEpoch});
  }


  void _showSettings(BuildContext context) { // Pass context
    showModalBottomSheet(
      context: context,
      backgroundColor: _surfaceColor,          // sheet surface
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(_isBackgroundServiceRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline, color: Colors.white70),
            title: Text(_isBackgroundServiceRunning ? "Stop Background Service" : "Start Background Service"),
            onTap: () {
              Navigator.pop(ctx); // Close bottom sheet
              _toggleBackgroundService();
            },
          ),
          const Divider(color: Colors.white24, height: 1),
          ListTile(
            leading: const Icon(Icons.account_circle, color: Colors.white70),
            title: const Text("Profile"),
            onTap: () {
              // TODO: Implement Profile
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: Colors.white70),
            title: const Text("Settings"),
            onTap: () {
              // TODO: Implement Settings
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<TrackerDevice> trackerList = _trackers.values.toList();
    trackerList.sort((a, b) => (b.lastTimestamp ?? DateTime(0)).compareTo(a.lastTimestamp ?? DateTime(0)));

    return Scaffold(
      appBar: AppBar(
        title: const Text("My Trackers"),
        backgroundColor: const Color(0xFF121212),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: GestureDetector(
              onTap: () => _showSettings(context),
              child: CircleAvatar(
                backgroundColor: const Color.fromARGB(255, 12, 55, 14),
                child: const Icon(Icons.person, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
      backgroundColor: const Color(0xFF121212),
      body: Column(
        children: [
          Expanded(
            flex: 1,
            child: GoogleMap(
              mapType: MapType.normal,
              initialCameraPosition: CameraPosition(
                target: _currentUserPosition != null
                    ? LatLng(_currentUserPosition!.latitude, _currentUserPosition!.longitude)
                    : const LatLng(20.5937, 78.9629),
                zoom: _currentUserPosition != null ? 13.0 : 4.0,  // lowered from 15 -> 13 and 5 -> 4
              ),
              onMapCreated: (GoogleMapController controller) {
                _googleMapController = controller;
                controller.setMapStyle(_darkMapStyle);
                if (_currentUserPosition != null) {
                  controller.animateCamera(
                    CameraUpdate.newLatLngZoom(
                      LatLng(_currentUserPosition!.latitude, _currentUserPosition!.longitude),
                      13.0,  // lowered from 15 -> 13
                    ),
                  );
                }
                _updateMarkersAndCamera();
              },
              markers: _markers,
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
              zoomControlsEnabled: false,
            ),
          ),
          const SizedBox(height: 8),  // add gap between map and list
          Expanded(
            flex: 1,
            child: trackerList.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.search_off, size: 48, color: Colors.white38),
                        const SizedBox(height: 16),
                        Text(
                          _isBackgroundServiceRunning
                              ? "Scanning for devices..."
                              : "Start background service to find trackers.",
                          style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        if (!_isBackgroundServiceRunning)
                          Padding(
                            padding: const EdgeInsets.only(top: 20.0),
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.play_arrow),
                              label: const Text("Start Service"),
                              onPressed: _toggleBackgroundService,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _accentAqua,              // accent aqua
                                foregroundColor: _primaryText,              // white text
                              ),
                            ),
                          )
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,       // remove horizontal inset
                    itemCount: trackerList.length,
                    itemBuilder: (context, i) {
                      final t = trackerList[i];
                      return Card(
                        color: _surfaceColor,         // full-width straight edges
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.color,
                            child: const Icon(Icons.location_on, size: 20),
                          ),
                          title: Text(
                            t.name,
                            style: const TextStyle(color: _primaryText, fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            "Last seen: ${t.lastPing}\nID: ...${t.id.substring(t.id.length - 6)}",
                            style: const TextStyle(color: _secondaryText),
                          ),
                          onTap: () {
                            if (t.lastLocation != null && _googleMapController != null) {
                              _googleMapController!.animateCamera(
                                CameraUpdate.newLatLngZoom(t.lastLocation!, 16.0), // fixed zoom showing ~100m radius
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
