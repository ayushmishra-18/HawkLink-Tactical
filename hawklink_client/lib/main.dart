// SOLDIER UPLINK - CLIENT SIDE
// Run this on Android/iOS devices for field operatives.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;
import 'sci_fi_ui.dart';
import 'heart_rate_scanner.dart';
import 'ar_compass.dart';
import 'acoustic_sensor.dart';
import 'models.dart'; // IMPORT SHARED MODELS

// --- CONFIGURATION ---
const int kPort = 4444;
const String kPreSharedKey = 'HAWKLINK_TACTICAL_SECURE_KEY_256';
const String kFixedIV =      'HAWKLINK_IV_16ch';

// NOTE: TacticalWaypoint class is in models.dart

void main() {
  runApp(const SoldierApp());
}

class SoldierApp extends StatefulWidget {
  const SoldierApp({super.key});
  @override
  State<SoldierApp> createState() => _SoldierAppState();
}

class _SoldierAppState extends State<SoldierApp> {
  bool _isStealthMode = false;
  void _toggleStealth() => setState(() => _isStealthMode = !_isStealthMode);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _isStealthMode ? Colors.black : kSciFiBlack,
        colorScheme: ColorScheme.dark(primary: _isStealthMode ? kSciFiRed : kSciFiGreen),
        textTheme: const TextTheme(bodyMedium: TextStyle(fontFamily: 'Courier')),
      ),
      home: UplinkScreen(isStealth: _isStealthMode, onToggleStealth: _toggleStealth),
    );
  }
}

class UplinkScreen extends StatefulWidget {
  final bool isStealth;
  final VoidCallback onToggleStealth;
  const UplinkScreen({super.key, required this.isStealth, required this.onToggleStealth});

  @override
  State<UplinkScreen> createState() => _UplinkScreenState();
}

class _UplinkScreenState extends State<UplinkScreen> with SingleTickerProviderStateMixin {
  Socket? _socket;
  String _status = "DISCONNECTED";
  String _bioStatus = "BIO-LINK STANDBY";
  final TextEditingController _ipController = TextEditingController(text: "192.168.1.X");
  final TextEditingController _idController = TextEditingController(text: "ALPHA-1");
  String _selectedRole = "ASSAULT";
  final List<String> _roles = ["ASSAULT", "MEDIC", "SCOUT", "SNIPER", "ENGINEER"];

  List<Map<String, dynamic>> _messages = [];
  bool _hasUnread = false;
  List<LatLng> _dangerZone = [];
  bool _isInDanger = false;
  Map<String, dynamic>? _pendingOrder;
  LatLng? _commanderObjective;
  List<TacticalWaypoint> _waypoints = [];

  // --- BIO METRICS ---
  int _heartRate = 75;
  int _spO2 = 98;
  int _systolic = 120;
  int _diastolic = 80;
  String get _bp => "$_systolic/$_diastolic";
  double _temp = 98.6;
  bool _isBioActive = false;

  // --- FATIGUE MONITOR ---
  int _fatigueAccumulator = 0;
  bool _isHeatStress = false;
  static const int kFatigueThresholdSeconds = 10;
  static const int kHighBpmThreshold = 150;

  // --- SENSORS ---
  Timer? _biometricTimer;
  Timer? _weatherTimer;

  final MapController _mapController = MapController();
  LatLng _myLocation = const LatLng(40.7128, -74.0060);
  double _heading = 0.0;
  List<Marker> _targetMarkers = [];
  bool _hasFix = false;
  Timer? _heartbeatTimer;
  final Battery _battery = Battery();
  final FlutterTts _tts = FlutterTts();
  final ImagePicker _picker = ImagePicker();
  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));
  late AnimationController _sosController;
  List<int> _incomingBuffer = [];

  AcousticSensor? _acousticSensor;
  bool _isGunshotDetected = false;

  @override
  void initState() {
    super.initState();
    _sosController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _startGpsTracking();
    _startCompass();
    _initTts();
    _initAcousticSensor();

    // BIO-SIMULATION LOOP
    _biometricTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          // --- SIMULATION (COMMENT OUT FOR REAL USE) ---
          int base = _sosController.isAnimating ? 130 : 75;
          if (Random().nextInt(20) == 0) base = 160;
          _heartRate = base + Random().nextInt(10) - 5;
          _spO2 = 96 + Random().nextInt(4);
          _systolic = 115 + Random().nextInt(10);
          _diastolic = 75 + Random().nextInt(10);
          _temp = 98.0 + Random().nextDouble();
          // ---------------------------------------------

          // Fatigue Logic
          if (_heartRate > kHighBpmThreshold) {
            _fatigueAccumulator++;
          } else {
            if (_fatigueAccumulator > 0) _fatigueAccumulator--;
          }

          if (_fatigueAccumulator >= kFatigueThresholdSeconds && !_isHeatStress) {
            _isHeatStress = true;
            if (!widget.isStealth) _tts.speak("Warning. Heat Stress Detected.");
            _sendPacket({'type': 'HEAT_STRESS', 'sender': _idController.text.toUpperCase(), 'val': true});
          } else if (_fatigueAccumulator == 0 && _isHeatStress) {
            _isHeatStress = false;
          }
        });
      }
    });

    _weatherTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      if (_hasFix) _fetchRealWeather();
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (_hasFix) _fetchRealWeather();
    });
  }

  Future<void> _fetchRealWeather() async {
    try {
      final url = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${_myLocation.latitude}&longitude=${_myLocation.longitude}&current_weather=true');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final double tempC = data['current_weather']['temperature'];
        if (mounted) {
          setState(() {
            _temp = (tempC * 9/5) + 32; // Convert to F
          });
        }
      }
    } catch (e) {
      debugPrint("Weather Error: $e");
    }
  }

  void _initAcousticSensor() {
    _acousticSensor = AcousticSensor(onGunshotDetected: _handleGunshot);
    _acousticSensor?.start();
  }

  void _handleGunshot() {
    setState(() => _isGunshotDetected = true);
    _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! SHOTS FIRED !!!'});
    if (!widget.isStealth) _tts.speak("Contact! Shots fired!");
    Future.delayed(const Duration(seconds: 2), () {
      if(mounted) setState(() => _isGunshotDetected = false);
    });
  }

  void _openBioScanner() {
    setState(() { _isBioActive = true; _bioStatus = "BIO-SCANNER ACTIVE"; });
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => HeartRateScanner(
            onReadingsDetected: (bpm, spo2, sys, dia) {
              setState(() {
                _heartRate = bpm;
                _spO2 = spo2;
                _systolic = sys;
                _diastolic = dia;
              });
            }
        )
    ).then((_) {
      setState(() => _bioStatus = "LAST: $_heartRate BPM | $_spO2% | ${_temp.toStringAsFixed(1)}°F");
    });
  }

  void _openAR() {
    if (!_hasFix) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("WAITING FOR POSITION FIX...")));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (c) => ArCompassView(waypoints: _waypoints, myLocation: _myLocation)));
  }

  void _initTts() async {
    await _tts.setLanguage("en-US");
    await _tts.setPitch(1.0);
    await _tts.setSpeechRate(0.5);
  }

  @override
  void dispose() {
    _socket?.destroy();
    _heartbeatTimer?.cancel();
    _biometricTimer?.cancel();
    _weatherTimer?.cancel();
    _acousticSensor?.stop();
    _sosController.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _sendTacticalImage() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera, maxWidth: 600, imageQuality: 40);
      if (photo != null) {
        if (_socket == null) await _connect();
        if (_socket != null) {
          final bytes = await File(photo.path).readAsBytes();
          final base64Image = base64Encode(bytes);
          _sendPacket({'type': 'IMAGE', 'sender': _idController.text.toUpperCase(), 'content': base64Image});
          if(!widget.isStealth) _tts.speak("Image Transmitted");
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: kSciFiGreen, content: Text("INTEL SENT")));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.red, content: Text("UPLINK FAILED")));
        }
      }
    } catch (e) {}
  }

  Future<void> _startGpsTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) { permission = await Geolocator.requestPermission(); if (permission == LocationPermission.denied) return; }

    const LocationSettings locationSettings = LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2);

    Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      if (mounted) {
        setState(() {
          _myLocation = LatLng(position.latitude, position.longitude);
          _hasFix = true;

          if (_temp == 0.0) _fetchRealWeather();
        });

        if (_dangerZone.isNotEmpty) {
          bool currentlyInDanger = _isPointInside(_myLocation, _dangerZone);
          if (currentlyInDanger && !_isInDanger && !widget.isStealth) _tts.speak("WARNING! Restricted Zone!");
          _isInDanger = currentlyInDanger;
        }
        if (_hasFix && _mapController.camera.zoom < 5) _mapController.move(_myLocation, 17);
      }
    });
  }

  void _startCompass() {
    FlutterCompass.events?.listen((CompassEvent event) { if (mounted) setState(() => _heading = event.heading ?? 0.0); });
  }

  bool _isPointInside(LatLng point, List<LatLng> polygon) {
    int intersectCount = 0;
    for (int j = 0; j < polygon.length - 1; j++) { if (_rayCastIntersect(point, polygon[j], polygon[j + 1])) intersectCount++; }
    return (intersectCount % 2) == 1;
  }

  bool _rayCastIntersect(LatLng point, LatLng vertA, LatLng vertB) {
    double aY = vertA.latitude; double bY = vertB.latitude; double aX = vertA.longitude; double bX = vertB.longitude; double pY = point.latitude; double pX = point.longitude;
    if ((aY > pY && bY > pY) || (aY < pY && bY < pY) || (aX < pX && bX < pX)) return false;
    double m = (aY - bY) / (aX - bX); double bee = (-aX) * m + aY; double x = (pY - bee) / m;
    return x > pX;
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() => _status = "SEARCHING...");
    try {
      _socket = await Socket.connect(_ipController.text, kPort, timeout: const Duration(seconds: 5));
      setState(() => _status = "SECURE UPLINK ESTABLISHED");
      if (!widget.isStealth) _tts.speak("Connected");
      _incomingBuffer = [];
      _socket!.listen((data) => _handleIncomingPacket(data), onDone: () { if (mounted) setState(() { _status = "CONNECTION LOST"; _socket = null; }); if (!widget.isStealth) _tts.speak("Connection Lost"); }, onError: (e) { if (mounted) setState(() { _status = "ERROR: $e"; _socket = null; }); });
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) => _sendHeartbeat());
    } catch (e) { if (mounted) setState(() { _status = "FAILED TO CONNECT"; _socket = null; }); }
  }

  void _disconnect() { _socket?.destroy(); if (mounted) setState(() { _status = "DISCONNECTED"; _socket = null; }); }

  void _handleIncomingPacket(List<int> data) {
    _incomingBuffer.addAll(data);
    try {
      final str = utf8.decode(data).trim();
      if (str.isEmpty) return;
      final decrypted = _encrypter.decrypt64(str, iv: _iv);
      final json = jsonDecode(decrypted);
      _processMessage(json);
      _incomingBuffer.clear();
    } catch(e) {}
  }

  void _processMessage(Map<String, dynamic> json) {
    if (json['type'] == 'KILL' && json['target'] == _idController.text.toUpperCase()) {
      _executeSelfDestruct();
      return;
    }

    if (json['type'] == 'ZONE') {
      List<dynamic> points = json['points'];
      setState(() => _dangerZone = points.map((p) => LatLng(p[0], p[1])).toList());
      if (!widget.isStealth) _tts.speak("Zone Updated");
    }
    else if (json['type'] == 'WAYPOINT') {
      if (json['action'] == 'ADD') {
        var data = json['data'];
        setState(() {
          _waypoints.add(TacticalWaypoint(id: data['id'], type: data['type'], location: LatLng(data['lat'], data['lng'])));
        });
        if(!widget.isStealth) _tts.speak("New Waypoint: ${data['type']}");
      } else if (json['action'] == 'REMOVE') {
        setState(() {
          _waypoints.removeWhere((wp) => wp.id == json['id']);
        });
      }
    }
    else if (json['type'] == 'MOVE_TO') {
      setState(() { _commanderObjective = LatLng(json['lat'], json['lng']); });
      _onMessageReceived(json);
    }
    else if (json['type'] == 'CHAT') {
      _onMessageReceived(json);
    }
  }

  Future<void> _executeSelfDestruct() async {
    _socket?.destroy();
    if (!mounted) exit(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.blue[900],
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.error_outline, size: 80, color: Colors.white),
              SizedBox(height: 20),
              Text("SYSTEM HALTED", style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold, fontFamily: 'Courier')),
              SizedBox(height: 10),
              Text("Error Code: 0xDEADBEEF", style: TextStyle(color: Colors.white, fontFamily: 'Courier')),
              Text("Memory Dump: Complete.", style: TextStyle(color: Colors.white, fontFamily: 'Courier')),
              Text("Zeroization: SUCCESS.", style: TextStyle(color: Colors.white, fontFamily: 'Courier')),
            ],
          ),
        ),
      ),
    );
    await Future.delayed(const Duration(seconds: 3));
    exit(0);
  }

  void _onMessageReceived(Map<String, dynamic> msg) {
    setState(() {
      _messages.insert(0, {'time': DateTime.now(), 'sender': msg['sender'], 'content': msg['content'], 'type': msg['type']});
      _hasUnread = true;
      _pendingOrder = msg;
    });
    if (!widget.isStealth) {
      String speech = msg['content'].replaceAll(RegExp(r'[^\w\s\.]'), '');
      _tts.speak(speech);
    }
  }

  void _sendHeartbeat() async {
    if (_socket == null) return;
    try {
      int bat = await _battery.batteryLevel;
      String state = _sosController.isAnimating ? "SOS" : "ACTIVE";
      if (_isInDanger) state = "DANGER";
      _sendPacket({
        'type': 'STATUS',
        'id': _idController.text.toUpperCase(),
        'role': _selectedRole,
        'lat': _myLocation.latitude,
        'lng': _myLocation.longitude,
        'head': _heading,
        'bat': bat,
        'state': state,
        'bpm': _heartRate,
        'spo2': _spO2,
        'bp': _bp,
        'temp': _temp,
        'heat': _isHeatStress,
        'dr': false // ALWAYS FALSE NOW
      });
    } catch (e) {}
  }

  void _sendPacket(Map<String, dynamic> data) {
    if (_socket == null) return;
    try {
      final jsonStr = jsonEncode(data);
      final encrypted = _encrypter.encrypt(jsonStr, iv: _iv).base64;
      _socket!.add(utf8.encode("$encrypted\n"));
    } catch (e) {}
  }

  void _activateSOS() {
    if (_sosController.isAnimating) {
      _sosController.reset();
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'SOS CANCELLED'});
      if(!widget.isStealth) _tts.speak("SOS Cancelled");
    } else {
      _sosController.repeat(reverse: true);
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! SOS ACTIVATED !!!'});
      if(!widget.isStealth) _tts.speak("Emergency Beacon");
      _sendHeartbeat();
    }
    setState(() {});
  }

  void _sendSitrep() {
    TextEditingController ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: kSciFiDarkBlue,
      title: Text("SEND SITREP", style: TextStyle(color: widget.isStealth ? kSciFiRed : kSciFiGreen, fontFamily: 'Orbitron')),
      content: TextField(controller: ctrl, style: const TextStyle(color: Colors.white, fontFamily: 'Courier'), decoration: const InputDecoration(hintText: "Report...", hintStyle: TextStyle(color: Colors.grey))),
      actions: [
        TextButton(child: Text("CANCEL", style: TextStyle(color: Colors.grey)), onPressed: () => Navigator.pop(ctx)),
        TextButton(child: Text("TRANSMIT", style: TextStyle(color: kSciFiGreen, fontWeight: FontWeight.bold)), onPressed: () { if (ctrl.text.isNotEmpty) { _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '[SITREP] ${ctrl.text}'}); Navigator.pop(ctx); } })
      ],
    ));
  }

  void _showLogs() {
    setState(() => _hasUnread = false);
    showModalBottomSheet(context: context, backgroundColor: kSciFiBlack, builder: (ctx) => Container(
      padding: const EdgeInsets.all(16),
      child: ListView.builder(itemCount: _messages.length, itemBuilder: (c, i) => ListTile(
        title: Text(_messages[i]['sender'], style: const TextStyle(color: kSciFiCyan, fontSize: 10, fontFamily: 'Orbitron')),
        subtitle: Text(_messages[i]['content'], style: const TextStyle(color: Colors.white, fontFamily: 'Courier')),
        trailing: Text(DateFormat('HH:mm').format(_messages[i]['time']), style: const TextStyle(color: Colors.grey, fontSize: 10)),
      )),
    ));
  }

  void _acknowledgeOrder() {
    if (_pendingOrder == null) return;
    _sendPacket({'type': 'ACK', 'sender': _idController.text.toUpperCase(), 'content': 'ORDER COPIED'});
    setState(() => _pendingOrder = null);
  }

  IconData _getWaypointIcon(String type) {
    switch (type) {
      case "RALLY": return Icons.flag;
      case "ENEMY": return Icons.warning_amber_rounded;
      case "MED": return Icons.medical_services;
      case "LZ": return Icons.flight_land;
      default: return Icons.location_on;
    }
  }

  Color _getWaypointColor(String type) {
    switch (type) {
      case "RALLY": return Colors.blueAccent;
      case "ENEMY": return kSciFiRed;
      case "MED": return Colors.white;
      case "LZ": return kSciFiGreen;
      default: return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isSOS = _sosController.isAnimating;
    final Color primaryColor = widget.isStealth ? kSciFiRed : kSciFiGreen;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const CrtOverlay(),
          // MAP LAYER
          ColorFiltered(
            colorFilter: widget.isStealth ? const ColorFilter.mode(Colors.black, BlendMode.saturation) : const ColorFilter.mode(Colors.transparent, BlendMode.multiply),
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _hasFix ? _myLocation : const LatLng(40.7128, -74.0060),
                initialZoom: 15,
                initialRotation: _heading,
                onLongPress: (tapPos, point) {
                  setState(() => _targetMarkers.add(Marker(point: point, width: 30, height: 30, child: const Icon(Icons.gps_fixed, color: Colors.orangeAccent))));
                  _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'TARGET AT ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}'});
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("TARGET MARKED")));
                },
              ),
              children: [
                TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: 'com.hawklink.soldier'),
                PolygonLayer(polygons: [if (_dangerZone.isNotEmpty) Polygon(points: _dangerZone, color: kSciFiRed.withOpacity(0.3), borderColor: kSciFiRed, borderStrokeWidth: 4, isFilled: true)]),

                MarkerLayer(markers: [
                  if (_hasFix) Marker(point: _myLocation, width: 40, height: 40, child: Transform.rotate(angle: (_heading * (pi / 180)), child: Icon(Icons.navigation, color: primaryColor, size: 35))),
                  ..._targetMarkers,
                  if (_commanderObjective != null) Marker(point: _commanderObjective!, width: 50, height: 50, child: Column(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), color: Colors.black, child: const Text("OBJ", style: TextStyle(color: Colors.yellowAccent, fontSize: 10, fontWeight: FontWeight.bold))), const Icon(Icons.flag, color: Colors.yellowAccent, size: 30)])),
                  ..._waypoints.map((wp) => Marker(
                      point: wp.location,
                      width: 50, height: 50,
                      child: Column(children: [
                        Icon(_getWaypointIcon(wp.type), color: _getWaypointColor(wp.type), size: 30),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)), child: Text(wp.type, style: const TextStyle(fontSize: 8, color: Colors.white)))
                      ])
                  ))
                ]),
              ],
            ),
          ),

          CrosshairOverlay(color: primaryColor),
          const CrtOverlay(),

          if (_isGunshotDetected) Container(color: kSciFiRed.withOpacity(0.5)),

          if (isSOS) AnimatedBuilder(animation: _sosController, builder: (ctx, ch) => Container(color: kSciFiRed.withOpacity(0.3 * _sosController.value))),
          if (_isInDanger) Container(decoration: BoxDecoration(border: Border.all(color: kSciFiRed, width: 10))),

          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SciFiPanel(
                    showBg: true,
                    borderColor: isSOS ? kSciFiRed : primaryColor,
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text("UPLINK: $_status", style: TextStyle(color: _socket != null ? primaryColor : kSciFiRed, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 10)),
                        IconButton(icon: Icon(widget.isStealth ? Icons.visibility_off : Icons.visibility, color: primaryColor, size: 18), onPressed: widget.onToggleStealth)
                      ]),

                      if (_isHeatStress)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text("⚠ HEAT STRESS WARNING", style: TextStyle(color: kSciFiRed, fontWeight: FontWeight.bold, fontSize: 12, backgroundColor: Colors.black54)),
                        ),

                      if (_socket == null) ...[
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(flex: 1, child: Container(height: 40, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: kSciFiDarkBlue, border: Border.all(color: primaryColor)), child: TextField(controller: _idController, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier'), decoration: const InputDecoration(border: InputBorder.none, hintText: "CALLSIGN")))),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: Container(height: 40, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: kSciFiDarkBlue, border: Border.all(color: primaryColor)), child: DropdownButtonFormField<String>(value: _selectedRole, dropdownColor: kSciFiBlack, decoration: const InputDecoration(border: InputBorder.none), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier'), items: _roles.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(), onChanged: (v) => setState(() => _selectedRole = v!)))),
                        ]),
                        const SizedBox(height: 8),
                        Row(children: [Expanded(child: Container(height: 40, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: kSciFiDarkBlue, border: Border.all(color: primaryColor)), child: TextField(controller: _ipController, style: const TextStyle(color: Colors.white, fontFamily: 'Courier'), decoration: const InputDecoration(border: InputBorder.none, hintText: "COMMAND IP")))), const SizedBox(width: 8), SciFiButton(label: "LINK", icon: Icons.link, color: primaryColor, onTap: _connect)])
                      ]
                      else Padding(padding: const EdgeInsets.only(top: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text("ID: ${_idController.text.toUpperCase()}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 14)),
                        IconButton(icon: const Icon(Icons.link_off, color: kSciFiRed), onPressed: _disconnect)
                      ]))
                    ]),
                  ),
                ),

                if (_pendingOrder != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: SciFiPanel(
                      borderColor: widget.isStealth ? kSciFiRed : kSciFiGreen,
                      title: "INCOMING ORDER // ${_pendingOrder!['sender']}",
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_pendingOrder!['content'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18, fontFamily: 'Courier')),
                        const SizedBox(height: 8),
                        SciFiButton(label: "ACKNOWLEDGE", icon: Icons.check_circle, color: Colors.white, onTap: _acknowledgeOrder)
                      ]),
                    ),
                  ),

                const Spacer(),

                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SciFiPanel(
                    showBg: true,
                    borderColor: primaryColor,
                    child: Column(children: [
                      Row(children: [
                        Expanded(child: SciFiButton(label: "BIO", icon: Icons.monitor_heart, color: _isBioActive ? kSciFiRed : Colors.grey, onTap: _openBioScanner)),
                        const SizedBox(width: 4),
                        Expanded(child: SciFiButton(label: "AR", icon: Icons.view_in_ar, color: kSciFiCyan, onTap: _openAR)),
                        const SizedBox(width: 4),
                        Expanded(child: SciFiButton(label: "CAM", icon: Icons.camera_alt, color: Colors.purpleAccent, onTap: _sendTacticalImage)),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(child: SciFiButton(label: "SITREP", icon: Icons.assignment, color: Colors.blue, onTap: _sendSitrep)),
                        const SizedBox(width: 4),
                        Expanded(child: SciFiButton(label: "LOGS", icon: _hasUnread ? Icons.mark_email_unread : Icons.history, color: _hasUnread ? kSciFiGreen : Colors.white, onTap: _showLogs)),
                      ]),
                      const SizedBox(height: 8),

                      Text(_bioStatus, style: TextStyle(color: _isBioActive ? kSciFiGreen : Colors.grey, fontSize: 10, fontFamily: 'Courier')),
                      const SizedBox(height: 8),

                      GestureDetector(
                          onLongPress: _activateSOS,
                          child: Container(
                              height: 50,
                              decoration: BoxDecoration(
                                  color: isSOS ? kSciFiRed.withOpacity(0.8) : kSciFiRed.withOpacity(0.2),
                                  border: Border.all(color: kSciFiRed, width: 2),
                                  borderRadius: BorderRadius.circular(4)
                              ),
                              child: Center(
                                  child: Text(isSOS ? "SOS ACTIVE" : "HOLD SOS", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier', letterSpacing: 2))
                              )
                          )
                      )
                    ]),
                  ),
                ),
              ],
            ),
          ),
          Positioned(top: 220, right: 16, child: FloatingActionButton(mini: true, backgroundColor: kSciFiBlack, child: Icon(Icons.my_location, color: primaryColor), onPressed: () { if (_hasFix) _mapController.move(_myLocation, 17); })),
        ],
      ),
    );
  }
}