import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'; // Added for permission checks
import '../add_tracker_screen.dart'; // Add this import
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../services/crypto_service.dart';

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

class AuthService {
  static Future<User?> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) return null;
    final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
    return userCredential.user;
  }

  static Future<void> signOut() async {
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
  }
}

class TrackerHomeScreen extends StatefulWidget {
  const TrackerHomeScreen({Key? key}) : super(key: key);

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

  List<Map<String, dynamic>> decryptedLocations = [];
  bool loading = true;

  Timer? _refreshTimer; // Timer to refresh locations

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
    fetchLocations();
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      fetchLocations();
    });
  }

  @override
  void dispose() {
    _googleMapController?.dispose();
    // Dispose any stream subscriptions
    _positionStreamSubscription?.cancel();
    _foundDeviceSubscription?.cancel();
    _pingResponseSubscription?.cancel();
    _refreshTimer?.cancel();
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


  void _showSettings(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    showModalBottomSheet(
      context: context,
      backgroundColor: _surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle, color: Colors.white70),
            title: Text(
              user != null
                  ? (user.displayName ?? user.email ?? "Signed In")
                  : "Not Signed In",
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (user == null)
            ListTile(
              leading: const Icon(Icons.login, color: Colors.green),
              title: const Text("Sign in with Google", style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                final signedInUser = await AuthService.signInWithGoogle();
                if (signedInUser != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Signed in as "+(signedInUser.displayName ?? signedInUser.email ?? ""))),
                  );
                }
              },
            ),
          if (user != null)
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text("Sign Out", style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                await AuthService.signOut();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Signed out")),
                  );
                }
              },
            ),
          const Divider(color: Colors.white24, height: 1),
          ListTile(
            leading: const Icon(Icons.settings, color: Colors.white70),
            title: const Text("Settings"),
            onTap: () {
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  Future<void> fetchLocations() async {
    setState(() { loading = true; });
    decryptedLocations.clear();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() { loading = false; });
      return;
    }
    final firestore = FirebaseFirestore.instance;
    final userDoc = await firestore.collection('User').doc(user.uid).get();
    final trackers = userDoc.data()?['trackers'] as Map<String, dynamic>?;
    if (trackers == null || trackers.isEmpty) {
      setState(() { loading = false; });
      return;
    }
    final storage = const FlutterSecureStorage();
    for (final eid in trackers.keys) {
      final trackerDoc = await firestore.collection('trackers').doc(eid).get();
      final data = trackerDoc.data()?['data'] as Map<String, dynamic>?;
      if (data == null || data['location+time'] == null) continue;
      List<String> encryptedArray = [];
      if (data['location+time'] is List) {
        encryptedArray = (data['location+time'] as List).whereType<String>().toList();
      } else if (data['location+time'] is String && (data['location+time'] as String).isNotEmpty) {
        try {
          final decodedList = jsonDecode(data['location+time'] as String);
          if (decodedList is List) {
            encryptedArray = decodedList.whereType<String>().toList();
          }
        } catch (e) {
          print('Error decoding location+time string for EID $eid: $e');
        }
      }
      final privateKeyB64 = await storage.read(key: eid);
      if (privateKeyB64 == null) continue;
      final privateKey = CryptoService.deserializePrivateKey(privateKeyB64);
      Map<String, dynamic>? latestLoc;
      for (final encrypted in encryptedArray) {
        if (encrypted.isEmpty) continue;
        try {
          final decrypted = CryptoService.decryptWithPrivateKey(privateKey, encrypted);
          final loc = jsonDecode(decrypted);
          if (latestLoc == null || (loc['ts'] != null && loc['ts'] > (latestLoc['ts'] ?? 0))) {
            latestLoc = {
              'eid': eid,
              'lat': loc['lat'],
              'lng': loc['lng'],
              'ts': loc['ts'],
            };
          }
        } catch (e) {
          print('Failed to decrypt location for EID $eid: $e');
        }
      }
      if (latestLoc != null) {
        decryptedLocations.add(latestLoc);
      }
    }
    setState(() { loading = false; });
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
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : decryptedLocations.isEmpty
                    ? const Center(child: Text('No tracker locations found.'))
                    : ListView.builder(
                        padding: EdgeInsets.zero,       // remove horizontal inset
                        itemCount: decryptedLocations.length,
                        itemBuilder: (context, idx) {
                          final loc = decryptedLocations[idx];
                          return Card(
                            color: _surfaceColor,
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: _accentGreen,
                                child: const Icon(Icons.location_on, size: 20),
                              ),
                              title: Text(
                                'EID: ${loc['eid']}',
                                style: const TextStyle(color: _primaryText, fontWeight: FontWeight.w500),
                              ),
                              subtitle: Text(
                                'Last seen: ${_formatTimestamp(DateTime.fromMillisecondsSinceEpoch(loc['ts']))}',
                                style: const TextStyle(color: _secondaryText),
                              ),
                              onTap: () {
                                if (loc['lat'] != null && loc['lng'] != null && _googleMapController != null) {
                                  _googleMapController!.animateCamera(
                                    CameraUpdate.newLatLngZoom(LatLng(loc['lat'], loc['lng']), 16.0),
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
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'service',
            onPressed: _toggleBackgroundService,
            backgroundColor: _isBackgroundServiceRunning ? Colors.red : Colors.green,
            child: Icon(_isBackgroundServiceRunning ? Icons.stop : Icons.play_arrow, color: Colors.white),
            tooltip: _isBackgroundServiceRunning ? 'Stop Service' : 'Start Service',
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'add',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AddTrackerScreen()),
              );
            },
            backgroundColor: Colors.teal,
            child: const Icon(Icons.add, color: Colors.white),
            tooltip: 'Add Tracker',
          ),
        ],
      ),
    );
  }
}
