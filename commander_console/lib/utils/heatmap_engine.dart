import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Represents a source of tactical "Heat" (Combat Activity)
class HeatPoint {
  final String id;
  final LatLng location;
  double intensity; // 0.0 to 1.0 (1.0 = Max Heat/Red)
  final DateTime timestamp;

  HeatPoint({
    required this.id,
    required this.location,
    this.intensity = 1.0,
    required this.timestamp,
  });
}

class HeatmapEngine {
  final List<HeatPoint> _heatPoints = [];
  Timer? _decayTimer;
  
  // Configuration
  static const double kDecayRate = 0.05; // Heat lost per tick
  static const Duration kDecayInterval = Duration(seconds: 2);
  
  List<HeatPoint> get points => List.unmodifiable(_heatPoints);

  void start() {
    _decayTimer?.cancel();
    _decayTimer = Timer.periodic(kDecayInterval, (timer) {
      _processDecay();
    });
  }

  void stop() {
    _decayTimer?.cancel();
  }

  void addEvent(String type, LatLng loc) {
    double initialHeat = 0.5;
    
    if (type == 'GUNSHOT') initialHeat = 1.0;
    if (type == 'EXPLOSION') initialHeat = 1.0;
    if (type == 'SIGHTING') initialHeat = 0.7;
    if (type == 'MOVEMENT') initialHeat = 0.3;

    // Check if close point exists to merge (Density aggregation)
    bool merged = false;
    for (var p in _heatPoints) {
      final dist = const Distance().as(LengthUnit.Meter, p.location, loc);
      if (dist < 50) { // Same area (50m radius)
        p.intensity = (p.intensity + 0.3).clamp(0.0, 1.0); // Boost heat
        merged = true;
        break;
      }
    }

    if (!merged) {
      _heatPoints.add(HeatPoint(
        id: DateTime.now().toIso8601String(),
        location: loc,
        intensity: initialHeat,
        timestamp: DateTime.now(),
      ));
    }
  }

  void _processDecay() {
    if (_heatPoints.isEmpty) return;
    
    for (var i = _heatPoints.length - 1; i >= 0; i--) {
      _heatPoints[i].intensity -= kDecayRate;
      if (_heatPoints[i].intensity <= 0) {
        _heatPoints.removeAt(i);
      }
    }
  }
}
