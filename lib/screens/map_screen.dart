import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class TrackerDevice {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final DateTime lastSeen;
  final double accuracy;
  final int rssi;

  TrackerDevice({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.lastSeen,
    required this.accuracy,
    this.rssi = 0,
  });
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _controller = Completer();
  
  // Start with a default position (can be updated when we get actual data)
  static const LatLng _center = LatLng(28.7041, 77.1025); // Default to Delhi, India
  
  // Store all tracker devices
  final List<TrackerDevice> _trackers = [];
  
  // Store markers for the map
  Set<Marker> _markers = {};
  
  // Track if the map is being loaded
  bool _isLoading = true;
  
  // User's current position
  LatLng? _currentUserPosition;
  
  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
    _listenForTrackerUpdates();
    _fetchTrackerLocations();
  }
  
  Future<void> _getCurrentLocation() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      
      setState(() {
        _currentUserPosition = LatLng(position.latitude, position.longitude);
        _isLoading = false;
      });
      
      _updateMapCamera();
    } catch (e) {
      debugPrint('Error getting location: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }
    void _listenForTrackerUpdates() {
    // Listen for data from the background service
    FlutterBackgroundService().on('foundDevice').listen((event) {
      if (event != null && event['fmdn'] != null && 
          event['location'] != null && mounted) {
        
        // Extract data from the background service event
        final deviceId = event['device'] as String;
        final deviceName = event['name'] as String? ?? 'Unknown';
        final lat = event['location']['latitude'] as double;
        final lng = event['location']['longitude'] as double;
        final accuracy = event['location']['accuracy'] as double;
        final rssi = event['rssi'] as int? ?? 0;
        
        // First, update the current user position
        if (event['location'] != null) {
          _currentUserPosition = LatLng(lat, lng);
        }
        
        // Check if we already have this tracker
        final existingIndex = _trackers.indexWhere((t) => t.id == deviceId);
        
        if (existingIndex >= 0) {
          // Update existing tracker
          _trackers[existingIndex] = TrackerDevice(
            id: deviceId,
            name: deviceName,
            lat: lat,
            lng: lng,
            lastSeen: DateTime.now(),
            accuracy: accuracy,
            rssi: rssi,
          );
        } else {
          // Add new tracker
          _trackers.add(
            TrackerDevice(
              id: deviceId,
              name: deviceName,
              lat: lat,
              lng: lng,
              lastSeen: DateTime.now(),
              accuracy: accuracy,
              rssi: rssi,
            ),
          );
        }
          // Update UI
        if (mounted) {
          _updateMarkers();
          // Focus the map on the current user's location
          _updateMapCamera();
        }
      }
    });
  }
  
  void _updateMarkers() {
    if (!mounted) return;
    
    Set<Marker> markers = {};
    
    // Add marker for user's location if available
    if (_currentUserPosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('user_location'),
          position: _currentUserPosition!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'Your Location'),
        ),
      );
    }
    
    // Add markers for each tracker
    for (var tracker in _trackers) {
      markers.add(
        Marker(
          markerId: MarkerId(tracker.id),
          position: LatLng(tracker.lat, tracker.lng),
          infoWindow: InfoWindow(
            title: tracker.name,
            snippet: 'Last seen: ${_formatLastSeen(tracker.lastSeen)} • RSSI: ${tracker.rssi} dBm',
          ),
          // Optional: customize marker based on tracker properties
          // icon: BitmapDescriptor.defaultMarkerWithHue(_getHueBasedOnRSSI(tracker.rssi)),
        ),
      );
      
      // Optionally add accuracy circles (requires custom overlay)
      // You would need to implement Circle overlays for this
    }
    
    setState(() {
      _markers = markers;
    });
  }
  
  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final difference = now.difference(lastSeen);
    
    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }
  
  Future<void> _updateMapCamera() async {
    if (_controller.isCompleted && _currentUserPosition != null) {
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _currentUserPosition!,
            zoom: 14.0,
          ),
        ),
      );
    }
  }
    Future<void> _fetchTrackerLocations() async {
    // Simulate fetching tracker locations from a server
    await Future.delayed(Duration(seconds: 2));

    // Get a base location - either user's current position or default center
    final baseLat = _currentUserPosition?.latitude ?? _center.latitude;
    final baseLng = _currentUserPosition?.longitude ?? _center.longitude;

    setState(() {
      _trackers.addAll([
        TrackerDevice(
          id: "server1",
          name: "Server Tracker 1",
          lat: baseLat + 0.001, // Closer to user's location
          lng: baseLng + 0.001,
          lastSeen: DateTime.now(),
          accuracy: 5.0,
        ),
        TrackerDevice(
          id: "server2",
          name: "Server Tracker 2",
          lat: baseLat - 0.001,
          lng: baseLng - 0.001,
          lastSeen: DateTime.now(),
          accuracy: 8.0,
        ),
      ]);

      _updateMarkers();
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tracker Map'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: () {
              _getCurrentLocation();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              // Manually refresh the map
              _updateMarkers();
              _updateMapCamera();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) {
              _controller.complete(controller);
            },
            initialCameraPosition: const CameraPosition(
              target: _center,
              zoom: 14.0,
            ),
            markers: _markers,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            zoomControlsEnabled: false,
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
      bottomSheet: Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(15),
            topRight: Radius.circular(15),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: const Text(
                'Tracked Devices',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _trackers.isEmpty
                  ? const Center(child: Text('No devices found yet'))
                  : ListView.builder(
                      itemCount: _trackers.length,
                      itemBuilder: (context, index) {
                        final tracker = _trackers[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.blue.withOpacity(0.2),
                            child: const Icon(Icons.bluetooth, color: Colors.blue),
                          ),
                          title: Text(tracker.name),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Last seen: ${_formatLastSeen(tracker.lastSeen)}'),
                              Text('Signal: ${tracker.rssi} dBm'),
                            ],
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                          onTap: () async {
                            final controller = await _controller.future;
                            controller.animateCamera(
                              CameraUpdate.newLatLngZoom(
                                LatLng(tracker.lat, tracker.lng),
                                16.0,
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
  
  // Unused method, can be removed
  // void _addDemoTrackers() {
  //   // Add some mock trackers
  //   _trackers.add(
  //     TrackerDevice(
  //       id: "demo1",
  //       name: "Demo Tracker 1",
  //       lat: 28.7041 + 0.01,
  //       lng: 77.1025 + 0.01,
  //       lastSeen: DateTime.now(),
  //       accuracy: 10.0,
  //     ),
  //   );
    
  //   _trackers.add(
  //     TrackerDevice(
  //       id: "demo2",
  //       name: "Demo Tracker 2",
  //       lat: 28.7041 - 0.01,
  //       lng: 77.1025 - 0.01,
  //       lastSeen: DateTime.now(),
  //       accuracy: 15.0,
  //     ),
  //   );
    
  //   _updateMarkers();
  // }
  
  // Unused method, can be removed
  // float _getHueBasedOnRSSI(int rssi) {
  //   // Convert RSSI to a hue value (red = weak, green = strong)
  //   // Example: map RSSI from -100 (weak) to -30 (strong) to hue 0 (red) to 120 (green)
  //   if (rssi <= -100) return 0.0; // Red
  //   if (rssi >= -30) return 120.0; // Green
  //   return ((rssi + 100) / 70.0) * 120.0;
  // }
  
  // Unused method, can be removed
  // void _showTrackersBottomSheet(BuildContext context) {
  //   showModalBottomSheet(
  //     context: context,
  //     builder: (BuildContext bc) {
  //       return Container(
  //         child: Wrap(
  //           children: <Widget>[
  //             ListView.builder(
  //               shrinkWrap: true, // Important to make ListView work in BottomSheet
  //               itemCount: _trackers.length,
  //               itemBuilder: (context, index) {
  //                 final tracker = _trackers[index];
  //                 return ListTile(
  //                   leading: Icon(Icons.bluetooth_searching),
  //                   title: Text(tracker.name),
  //                   subtitle: Text(
  //                       'Lat: ${tracker.lat.toStringAsFixed(4)}, Lng: ${tracker.lng.toStringAsFixed(4)}\\nLast Seen: ${_formatLastSeen(tracker.lastSeen)}'),
  //                   onTap: () async {
  //                     final controller = await _controller.future;
  //                     controller.animateCamera(
  //                       CameraUpdate.newLatLngZoom(
  //                         LatLng(tracker.lat, tracker.lng),
  //                         16.0, // Zoom level when focusing on a tracker
  //                       ),
  //                     );
  //                     Navigator.pop(context); // Close the bottom sheet
  //                   },
  //                 );
  //               },
  //             ),
  //           ],
  //         ),
  //       );
  //     },
  //   );
  // }    
}