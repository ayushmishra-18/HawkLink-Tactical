// SHARED MODELS
// Use this file to define classes shared between screens to avoid circular dependencies.

import 'package:latlong2/latlong.dart';

class TacticalWaypoint {
  String id;
  String type;
  LatLng location;

  TacticalWaypoint({
    required this.id,
    required this.type,
    required this.location
  });
}