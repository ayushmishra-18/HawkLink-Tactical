import 'package:latlong2/latlong.dart';
import 'dart:io';

class SoldierUnit {
  String id;
  String role;
  LatLng location;
  double heading;
  int battery;
  int bpm;
  int spO2;
  String bp;
  double temp;
  String status;
  bool isHeatStress;
  bool isDeadReckoning;
  bool inDangerZone;

  DateTime lastSeen;
  Socket? socket;
  List<LatLng> pathHistory;

  int get secondsSincePing => DateTime.now().difference(lastSeen).inSeconds;

  SoldierUnit({
    required this.id,
    this.role="ASSAULT",
    required this.location,
    this.heading=0.0,
    this.battery=100,
    this.bpm=75,
    this.spO2=98,
    this.bp="120/80",
    this.temp=98.6,
    this.status="IDLE",
    this.isHeatStress = false,
    this.isDeadReckoning = false,
    this.inDangerZone = false,
    required this.lastSeen,
    this.socket,
    this.triageColor = "FF00FF00", // Default Green (ARGB)
    this.isCasevacRequested = false,
    List<LatLng>? history
  }) : pathHistory = history ?? [];

  // New Fields
  String triageColor;
  bool isCasevacRequested;
}

class TacticalWaypoint {
  String id; String type; LatLng location; DateTime created;
  TacticalWaypoint({required this.id, required this.type, required this.location, required this.created});
  Map<String, dynamic> toJson() => {'id': id, 'type': type, 'lat': location.latitude, 'lng': location.longitude, 'time': created.toIso8601String()};
}

class TerrainData {
  double temperature;
  double windSpeed;
  String windDirection;
  String condition;
  double visibility;

  TerrainData({
    this.temperature = 25.0,
    this.windSpeed = 10.0,
    this.windDirection = 'NW',
    this.condition = 'Clear',
    this.visibility = 10.0,
  });

  Map<String, dynamic> toJson() => {
    'temp': temperature,
    'wind': windSpeed,
    'dir': windDirection,
    'cond': condition,
    'vis': visibility,
  };
}
