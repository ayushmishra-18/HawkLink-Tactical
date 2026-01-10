import 'dart:async';
import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter/foundation.dart';

/// Handles Dead Reckoning (DR) navigation when GPS is unavailable.
/// Uses Accelerometer for step detection and Magnetometer for heading.
class DeadReckoningEngine {
  // Streams
  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  
  // State
  bool _isActive = false;
  LatLng _lastKnownPosition = const LatLng(0, 0);
  double _currentHeading = 0.0;
  
  // Step Detection
  static const double _stepThreshold = 12.0; // Acceleration magnitude threshold
  static const int _stepDelayMs = 400; // Min time between steps
  int _lastStepTime = 0;
  final double _stepLengthMeters = 0.75; // Approx step length
  
  // Output Stream
  final _positionController = StreamController<LatLng>.broadcast();
  Stream<LatLng> get positionStream => _positionController.stream;

  bool get isActive => _isActive;

  /// Initialize and start sensors
  Future<void> start(LatLng startPos) async {
    if (_isActive) return;
    _isActive = true;
    _lastKnownPosition = startPos;
    debugPrint("DR ENGINE: Started at $startPos");

    // Listen to device motion (UserAccelerometer excludes gravity)
    _accelSub = userAccelerometerEventStream().listen(_onAccelEvent);
    
    // Listen to compass
    _magSub = magnetometerEventStream().listen(_onMagEvent);
  }

  /// Stop sensors
  void stop() {
    _isActive = false;
    _accelSub?.cancel();
    _magSub?.cancel();
    debugPrint("DR ENGINE: Stopped");
  }

  /// Update the anchor position when GPS returns
  void syncPosition(LatLng fix) {
    _lastKnownPosition = fix;
    // debugPrint("DR ENGINE: Synced to $fix");
  }

  void _onMagEvent(MagnetometerEvent event) {
    // Simple 2D heading calculation
    // In real app, would use rotation matrix with accelerometer
    double heading = atan2(event.y, event.x);
    heading = (heading * 180 / pi); 
    // Normalize to 0-360
    if (heading < 0) heading += 360;
    
    // Adjust for screen orientation/device hold (simplified)
    // Assuming device held portrait flat
    _currentHeading = heading;
  }

  void _onAccelEvent(UserAccelerometerEvent event) {
    // Calculate magnitude
    double mag = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    
    // Simple Step Detector
    // If magnitude > threshold and enough time passed since last step
    int now = DateTime.now().millisecondsSinceEpoch;
    if (mag > 2.0 && (now - _lastStepTime) > _stepDelayMs) {
      _lastStepTime = now;
      _processStep();
    }
  }

  void _processStep() {
    // Calculate new position based on heading and step length
    // Destination point given distance and bearing from start point
    
    final double dist = _stepLengthMeters / 6371000.0; // Angular distance in radians
    final double brng = _currentHeading * (pi / 180); // Convert bearing to radiants
    
    final double lat1 = _lastKnownPosition.latitude * (pi / 180);
    final double lon1 = _lastKnownPosition.longitude * (pi / 180);

    final double lat2 = asin(sin(lat1) * cos(dist) + cos(lat1) * sin(dist) * cos(brng));
    final double lon2 = lon1 + atan2(sin(brng) * sin(dist) * cos(lat1), cos(dist) - sin(lat1) * sin(lat2));

    _lastKnownPosition = LatLng(lat2 * (180 / pi), lon2 * (180 / pi));
    
    // Emit new estimated position
    _positionController.add(_lastKnownPosition);
    debugPrint("DR STEP: $_lastKnownPosition (Head: $_currentHeading)");
  }
}
