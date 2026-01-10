import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:latlong2/latlong.dart';
import 'models.dart'; // IMPORT SHARED MODELS
import 'sci_fi_ui.dart';

class ArCompassView extends StatefulWidget {
  final List<TacticalWaypoint> waypoints;
  final List<SoldierUnit> teammates;
  final LatLng myLocation;

  const ArCompassView({super.key, required this.waypoints, required this.teammates, required this.myLocation});

  @override
  State<ArCompassView> createState() => _ArCompassViewState();
}

class _ArCompassViewState extends State<ArCompassView> {
  CameraController? _controller;
  double _heading = 0.0;
  final Distance _distance = const Distance();

  @override
  void initState() {
    super.initState();
    _initCamera();
    // Listen to compass
    FlutterCompass.events?.listen((event) {
      if (mounted) setState(() => _heading = event.heading ?? 0);
    });
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        _controller = CameraController(cameras.first, ResolutionPreset.medium, enableAudio: false);
        await _controller!.initialize();
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint("AR ERROR: $e");
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // Calculate bearing from user to waypoint (0-360 degrees)
  double _getBearing(LatLng p1, LatLng p2) {
    var dLon = (p2.longitude - p1.longitude) * pi / 180;
    var lat1 = p1.latitude * pi / 180;
    var lat2 = p2.latitude * pi / 180;
    var y = sin(dLon) * cos(lat2);
    var x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    var brng = atan2(y, x);
    return (brng * 180 / pi + 360) % 360;
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: kSciFiGreen));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Camera Feed
          SizedBox.expand(child: CameraPreview(_controller!)),

          // 2. HUD Overlay (Grid)
          const CrtOverlay(),

          // 3. AR Icons
          ...widget.waypoints.map((wp) {
            double bearing = _getBearing(widget.myLocation, wp.location);
            double delta = bearing - _heading;

            // Normalize delta to -180 to +180
            if (delta > 180) delta -= 360;
            if (delta < -180) delta += 360;

            // Field of View (FOV) approximation (~60 degrees visible)
            // If delta is within -30 to +30, show it on screen
            bool isVisible = delta.abs() < 40;

            // Map delta (-30 to 30) to screen width
            // 0 -> Center of screen
            double screenW = MediaQuery.of(context).size.width;
            double leftPos = (screenW / 2) + (delta * (screenW / 60));

            double dist = _distance.as(LengthUnit.Meter, widget.myLocation, wp.location);

            if (!isVisible) return const SizedBox();

            return Positioned(
              left: leftPos - 30, // Centered
              top: MediaQuery.of(context).size.height / 3, // Floating at eye level
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      border: Border.all(color: _getColor(wp.type), width: 2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(_getIcon(wp.type), color: _getColor(wp.type), size: 32),
                  ),
                  const SizedBox(height: 4),
                  Text("${wp.type}\n${dist.toInt()}m",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _getColor(wp.type), fontWeight: FontWeight.bold, fontSize: 12, backgroundColor: Colors.black45)
                  )
                ],
              ),
            );
          }),
          
          // 3b. AR Teammates
          ...widget.teammates.map((u) {
            double bearing = _getBearing(widget.myLocation, u.location);
            double delta = bearing - _heading;
            if (delta > 180) delta -= 360;
            if (delta < -180) delta += 360;

            bool isVisible = delta.abs() < 40;
            double screenW = MediaQuery.of(context).size.width;
            double leftPos = (screenW / 2) + (delta * (screenW / 60));
            double dist = _distance.as(LengthUnit.Meter, widget.myLocation, u.location);

            if (!isVisible) return const SizedBox();

            return Positioned(
              left: leftPos - 35,
              top: MediaQuery.of(context).size.height / 2.5, // Slightly lower than waypoints
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                       color: Colors.black54,
                       shape: BoxShape.circle,
                       border: Border.all(color: Colors.cyanAccent, width: 2)
                    ),
                    child: Icon(_getRoleIcon(u.role), color: Colors.cyanAccent, size: 28),
                  ),
                  const SizedBox(height: 4),
                  Text("${u.id}\n${dist.toInt()}m",
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 10, backgroundColor: Colors.black45)
                  )
                ],
              ),
            );
          }),

          // 4. Back Button & Heading Tape
          Positioned(
            top: 40, left: 0, right: 0,
            child: Column(
              children: [
                SciFiPanel(
                  width: 150,
                  borderColor: kSciFiGreen,
                  child: Text("${_heading.toInt()}° MAG", textAlign: TextAlign.center, style: const TextStyle(color: kSciFiGreen, fontSize: 20, fontFamily: 'Orbitron')),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 30, left: 30,
            child: SciFiButton(label: "EXIT AR", icon: Icons.arrow_back, color: kSciFiRed, onTap: () => Navigator.pop(context)),
          )
        ],
      ),
    );
  }

  IconData _getIcon(String t) {
    switch(t){case "RALLY":return Icons.flag; case "ENEMY":return Icons.warning; case "MED":return Icons.medical_services; default:return Icons.location_on;}
  }
  Color _getColor(String t) {
    switch(t){case "RALLY":return Colors.blue; case "ENEMY":return kSciFiRed; case "MED":return Colors.white; default:return kSciFiGreen;}
  }
  
  IconData _getRoleIcon(String r) { 
    switch(r){ case "MEDIC": return Icons.medical_services; case "SCOUT": return Icons.visibility; case "SNIPER": return Icons.gps_fixed; case "ENGINEER": return Icons.build; default: return Icons.shield; } 
  }
}