// SOLDIER UPLINK - CLIENT SIDE
// Run this on Android/iOS devices for field operatives.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math'; // Imports sin, cos, pi directly
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path; // FIX: Hide Path to avoid conflict with dart:ui
import 'package:intl/intl.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:record/record.dart'; // v5.2.0 uses AudioRecorder
import 'package:path_provider/path_provider.dart';
import 'sci_fi_ui.dart';
import 'heart_rate_scanner.dart';
import 'ar_compass.dart';
import 'acoustic_sensor.dart';
import 'models.dart';
import 'package:permission_handler/permission_handler.dart';

// --- CONFIGURATION ---
const int kPort = 4444;
const String kPreSharedKey = 'HAWKLINK_TACTICAL_SECURE_KEY_256';
const String kFixedIV =      'HAWKLINK_IV_16ch';

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
  int _heartRate = 0;
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

  // --- ENVIRONMENT / TERRAIN DATA ---
  double _envTemp = 25.0;
  double _envWind = 10.0;
  String _envCond = 'Clear';

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
  bool _isMicPermissionGranted = false;

  // --- BLACK BOX RECORDER VARS (v5 API) ---
  final AudioRecorder _audioRecorder = AudioRecorder(); // Uses v5 API class
  bool _isBlackBoxActive = false;
  Timer? _blackBoxChunkTimer;
  int _blackBoxRecordingTime = 0;

  // Distance Calc
  final Distance _distanceCalc = const Distance();

  // Mobile Scanner
  bool _isScanProcessing = false;

  // --- ROLE SPECIFIC STATE ---
  int _ammoCount = 30; // Assault
  int _magCount = 4;   // Assault
  Timer? _demoTimer;   // Engineer
  int _demoSeconds = 0; // Engineer

  // --- UI STATE ---
  bool _isTopPanelVisible = true;

  @override
  void initState() {
    super.initState();
    _sosController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _startGpsTracking();
    _startCompass();
    _initTts();

    _initAcousticSensor();

    _biometricTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_heartRate > 0) {
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
            if (_envCond == 'Clear') {
              _envTemp = tempC;
              _envWind = data['current_weather']['windspeed'];
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Weather Error: $e");
    }
  }

  Future<void> _initAcousticSensor() async {
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }

    if (status.isGranted) {
      _acousticSensor = AcousticSensor(onGunshotDetected: _handleGunshot);
      await _acousticSensor?.start();
      if(mounted) setState(() => _isMicPermissionGranted = true);
    }
  }

  void _handleGunshot() {
    if (!mounted) return;
    setState(() => _isGunshotDetected = true);
    _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! SHOTS FIRED !!!'});
    if (!widget.isStealth) _tts.speak("Contact! Shots fired!");
    Future.delayed(const Duration(seconds: 2), () {
      if(mounted) setState(() => _isGunshotDetected = false);
    });
  }

  void _openBioScanner() {
    setState(() { _isBioActive = true; _bioStatus = "INITIALIZING SENSORS..."; });
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
      setState(() {
        _isBioActive = false;
        if (_heartRate > 0) {
          _bioStatus = "VITAL: $_heartRate BPM | $_spO2% SpO2";
        } else {
          _bioStatus = "SCAN ABORTED";
        }
      });
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
    _blackBoxChunkTimer?.cancel();
    _audioRecorder.dispose();
    _acousticSensor?.stop();
    _sosController.dispose();
    _demoTimer?.cancel();
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

          if (_temp == 98.6) _fetchRealWeather();
        });

        if (_dangerZone.isNotEmpty) {
          bool currentlyInDanger = _isPointInside(_myLocation, _dangerZone);
          if (currentlyInDanger && !_isInDanger && !widget.isStealth) {
            _tts.speak("WARNING! Restricted Zone!");
            _handleGeofenceBreach();
          }
          _isInDanger = currentlyInDanger;
        }
        if (_hasFix && _mapController.camera.zoom < 5) _mapController.move(_myLocation, 17);
      }
    });
  }

  void _handleGeofenceBreach() {
    _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! BREACHING DANGER ZONE !!!'});
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
    else if (json['type'] == 'BREACH') {
      _onMessageReceived(json);
      setState(() => _isInDanger = true);
      if(!widget.isStealth) _tts.speak("Alert! You are in a restricted area!");
    }
    else if (json['type'] == 'TERRAIN') {
      var data = json['data'];
      setState(() {
        _envTemp = (data['temp'] as num).toDouble();
        _envWind = (data['wind'] as num).toDouble();
        _envCond = data['cond'];
      });
      if (!widget.isStealth) _tts.speak("Environment Update. Condition: $_envCond");
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

  void _triggerBurnBag() {
    _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! TRIGGERING BURN BAG !!!'});
    _socket?.destroy();
    showDialog(context: context, barrierDismissible: false, builder: (c) => Container(color: Colors.black, child: const Center(child: Text("WIPING DATA...", style: TextStyle(color: Colors.red, fontSize: 30, decoration: TextDecoration.none)))));
    Future.delayed(const Duration(seconds: 2), () => exit(0));
  }

  // --- BLACK BOX LOGIC (v5 API) ---
  Future<void> _triggerBlackBox() async {
    if (_isBlackBoxActive) {
      // STOP Recording
      _blackBoxChunkTimer?.cancel();
      await _stopAndSendChunk();
      setState(() {
        _isBlackBoxActive = false;
        _blackBoxRecordingTime = 0;
      });
      if (!widget.isStealth) _tts.speak("Black Box Deactivated");
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'BLACK BOX: HALTED'});
    } else {
      // START Recording
      if (await _audioRecorder.hasPermission()) {
        setState(() {
          _isBlackBoxActive = true;
          _blackBoxRecordingTime = 0;
        });
        if (!widget.isStealth) _tts.speak("Black Box Recording");
        _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'BLACK BOX: RECORDING STARTED'});

        // Start first chunk
        await _startRecordingChunk();

        // Timer to cycle chunks every 10 seconds
        _blackBoxChunkTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
          setState(() => _blackBoxRecordingTime += 10);
          _cycleRecordingChunk();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("MIC PERMISSION DENIED")));
      }
    }
  }

  Future<void> _startRecordingChunk() async {
    final dir = await getTemporaryDirectory();
    String filePath = '${dir.path}/blackbox_${DateTime.now().millisecondsSinceEpoch}.m4a';

    // v5 API - Using RecordConfig
    const config = RecordConfig(encoder: AudioEncoder.aacLc);
    await _audioRecorder.start(config, path: filePath);
  }

  Future<void> _stopAndSendChunk() async {
    // v5 API returns path on stop
    final path = await _audioRecorder.stop();

    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final base64Audio = base64Encode(bytes);

        // --- CRITICAL FIX: Ensure non-null values for metadata ---
        // Grab current state values locally
        double lat = _myLocation.latitude;
        double lng = _myLocation.longitude;
        int bpm = _heartRate;
        int spo2 = _spO2;
        String bp = _bp;

        // Send packet with EXTRA TELEMETRY
        _sendPacket({
          'type': 'INTEL_AUDIO',
          'sender': _idController.text.toUpperCase(),
          'content': base64Audio,
          'duration': '10s',
          'timestamp': DateTime.now().toIso8601String(),
          // NEW FIELDS ADDED HERE with Explicit values
          'lat': lat,
          'lng': lng,
          'bpm': bpm,
          'spO2': spo2,
          'bp': bp,
        });

        // Cleanup temp file
        await file.delete();
      }
    }
  }

  Future<void> _cycleRecordingChunk() async {
    await _stopAndSendChunk();
    if (_isBlackBoxActive) {
      await _startRecordingChunk();
    }
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
        'dr': false
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

  // --- WGS 84 Formatter ---
  String _formatCoords(LatLng l) {
    String latDir = l.latitude >= 0 ? "N" : "S";
    String lngDir = l.longitude >= 0 ? "E" : "W";
    return "${l.latitude.abs().toStringAsFixed(5)}° $latDir\n${l.longitude.abs().toStringAsFixed(5)}° $lngDir";
  }

  // --- ROLE SPECIFIC UI BUILDERS ---

  Widget _buildSniperCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.orange), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("BALLISTICS COMPUTER", style: TextStyle(color: Colors.orange, fontSize: 10, fontFamily: 'Orbitron')),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text("WIND: ${_envWind.toStringAsFixed(1)} km/h", style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'Courier')),
          Text("ADJ: ${(_envWind * 0.1).toStringAsFixed(2)} MIL", style: const TextStyle(color: kSciFiCyan, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Courier')),
        ]),
        const Text("TEMP CORR: OK", style: TextStyle(color: kSciFiGreen, fontSize: 10)),
      ]),
    );
  }

  Widget _buildAssaultUI() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.redAccent), borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("AMMO COUNT", style: TextStyle(color: Colors.redAccent, fontSize: 10, fontFamily: 'Orbitron')),
          Row(children: [
            Text("$_ammoCount", style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
            const Text("/30", style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
          Text("MAGS: $_magCount", style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
        Column(children: [
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red.withOpacity(0.3)), onPressed: () => setState(() { if(_ammoCount > 0) _ammoCount--; else if (_magCount > 0) {_magCount--; _ammoCount=30;} }), child: const Text("FIRE")),
          const SizedBox(height: 4),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.withOpacity(0.3)), onPressed: () => setState(() { if (_magCount > 0) {_magCount--; _ammoCount=30;} }), child: const Text("RELOAD")),
        ])
      ]),
    );
  }

  Widget _buildMedicUI() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: kSciFiGreen), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("SQUAD VITALS (SIM)", style: TextStyle(color: kSciFiGreen, fontSize: 10, fontFamily: 'Orbitron')),
        const SizedBox(height: 4),
        _buildSquadMemberStatus("ALPHA-1 (YOU)", _heartRate, 100),
        _buildSquadMemberStatus("BRAVO-6", 88, 92),
        _buildSquadMemberStatus("CHARLIE-2", 110, 45),
      ]),
    );
  }

  Widget _buildSquadMemberStatus(String id, int hr, int hp) {
    Color c = hp > 80 ? kSciFiGreen : (hp > 40 ? Colors.orange : Colors.red);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
      Text(id, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
      const Spacer(),
      Text("HR: $hr", style: TextStyle(color: c, fontSize: 12)),
      const SizedBox(width: 8),
      Text("HP: $hp%", style: TextStyle(color: c, fontSize: 12)),
    ]));
  }

  Widget _buildScoutUI() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.blue), borderRadius: BorderRadius.circular(4)),
      child: Column(children: [
        const Text("QUICK MARK", style: TextStyle(color: Colors.blue, fontSize: 10, fontFamily: 'Orbitron')),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _buildQuickMarkBtn("INFANTRY", Icons.directions_walk),
          _buildQuickMarkBtn("VEHICLE", Icons.directions_car),
          _buildQuickMarkBtn("TRAP", Icons.warning),
        ]),
      ]),
    );
  }

  Widget _buildQuickMarkBtn(String label, IconData icon) {
    return InkWell(
      onTap: () {
        _sendPacket({'type': 'CHAT', 'sender': _idController.text, 'content': 'SPOTREP: $label at current pos'});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("MARKED $label")));
      },
      child: Column(children: [
        Icon(icon, color: Colors.blue, size: 20),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 10))
      ]),
    );
  }

  Widget _buildEngineerUI() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.orangeAccent), borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("DEMO TIMER", style: TextStyle(color: Colors.orangeAccent, fontSize: 10, fontFamily: 'Orbitron')),
          Text("T-${_demoSeconds}s", style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        ]),
        Column(children: [
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red.withOpacity(0.3)), onPressed: () { setState(() => _demoSeconds = 60); _demoTimer?.cancel(); _demoTimer = Timer.periodic(const Duration(seconds: 1), (t) { setState(() { if(_demoSeconds > 0) _demoSeconds--; else t.cancel(); }); }); }, child: const Text("SET 60s")),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.withOpacity(0.3)), onPressed: () { _demoTimer?.cancel(); setState(() => _demoSeconds = 0); }, child: const Text("ABORT")),
        ])
      ]),
    );
  }

  Widget _buildRoleSpecificUI() {
    switch (_selectedRole) {
      case "ASSAULT": return _buildAssaultUI();
      case "MEDIC": return _buildMedicUI();
      case "SCOUT": return _buildScoutUI();
      case "SNIPER": return _buildSniperCard();
      case "ENGINEER": return _buildEngineerUI();
      default: return const SizedBox.shrink();
    }
  }

  // --- QR CODE SCANNER (QUICK JOIN) ---
  void _openQRScanner() {
    _isScanProcessing = false;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text("SCAN UPLINK QR"), backgroundColor: Colors.black),
          body: MobileScanner(
            controller: MobileScannerController(
              detectionSpeed: DetectionSpeed.noDuplicates,
            ),
            onDetect: (capture) {
              if (_isScanProcessing) return;

              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  final parts = barcode.rawValue!.split('|');
                  if (parts.length >= 1) {
                    _isScanProcessing = true;
                    Future.delayed(Duration(milliseconds: 100), () {
                      if (context.mounted) {
                        setState(() {
                          _ipController.text = parts[0];
                        });
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("QR SCANNED: CONNECTING...")));
                        _connect();
                      }
                    });
                    return;
                  }
                }
              }
            },
          ),
        ),
      ),
    );
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

          // --- SLIDING TOP PANEL ---
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.fastOutSlowIn, // Smoother slide
            top: _isTopPanelVisible ? 0 : -220, // Adjusted height
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // THE PANEL ITSELF
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 0),
                    child: SciFiPanel(
                      showBg: true,
                      borderColor: isSOS ? kSciFiRed : primaryColor,
                      child: Column(children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text("UPLINK: $_status", style: TextStyle(color: _socket != null ? primaryColor : kSciFiRed, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 10)),
                          IconButton(icon: Icon(widget.isStealth ? Icons.visibility_off : Icons.visibility, color: primaryColor, size: 18), onPressed: widget.onToggleStealth)
                        ]),

                        // --- DISPLAY LOCATION ---
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(_formatCoords(_myLocation),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'Courier', letterSpacing: 1.0)
                          ),
                        ),

                        if (_isHeatStress)
                          Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text("⚠ HEAT STRESS WARNING", style: TextStyle(color: kSciFiRed, fontWeight: FontWeight.bold, fontSize: 12, backgroundColor: Colors.black54)),
                          ),

                        // --- TERRAIN INFO PANEL ---
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.thermostat, size: 12, color: Colors.grey),
                              Text(" ${_envTemp.toStringAsFixed(0)}°C ", style: const TextStyle(color: Colors.white, fontSize: 10)),
                              const SizedBox(width: 8),
                              Icon(Icons.air, size: 12, color: Colors.grey),
                              Text(" ${_envWind.toStringAsFixed(0)} km/h ", style: const TextStyle(color: Colors.white, fontSize: 10)),
                              const SizedBox(width: 8),
                              Text(_envCond.toUpperCase(), style: TextStyle(color: _envCond == 'Clear' ? kSciFiGreen : Colors.orange, fontSize: 10)),
                            ],
                          ),
                        ),

                        // --- ROLE SPECIFIC UI WIDGET ---
                        _buildRoleSpecificUI(),

                        // --- WAYPOINT HUD ---
                        if (_waypoints.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: SizedBox(
                              height: 30,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: _waypoints.map((wp) {
                                  int dist = _distanceCalc.as(LengthUnit.Meter, _myLocation, wp.location).toInt();
                                  return Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: _getWaypointColor(wp.type).withOpacity(0.2),
                                        border: Border.all(color: _getWaypointColor(wp.type)),
                                        borderRadius: BorderRadius.circular(2)
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(_getWaypointIcon(wp.type), color: _getWaypointColor(wp.type), size: 10),
                                        const SizedBox(width: 4),
                                        Text("${wp.type}: ${dist}m", style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Orbitron'))
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),

                        if (_socket == null) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(flex: 1, child: Container(height: 35, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: kSciFiDarkBlue, border: Border.all(color: primaryColor)), child: TextField(controller: _idController, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 12), decoration: const InputDecoration(border: InputBorder.none, hintText: "CALLSIGN")))),
                            const SizedBox(width: 8),
                            Expanded(flex: 2, child: Container(height: 35, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: kSciFiDarkBlue, border: Border.all(color: primaryColor)), child: DropdownButtonFormField<String>(value: _selectedRole, dropdownColor: kSciFiBlack, decoration: const InputDecoration(border: InputBorder.none), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 12), items: _roles.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(), onChanged: (v) => setState(() => _selectedRole = v!)))),
                          ]),
                          const SizedBox(height: 8),
                          // --- UPDATED ROW WITH QR SCANNER BUTTON ---
                          Row(children: [
                            Expanded(child: Container(height: 35, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: kSciFiDarkBlue, border: Border.all(color: primaryColor)), child: TextField(controller: _ipController, style: const TextStyle(color: Colors.white, fontFamily: 'Courier', fontSize: 12), decoration: const InputDecoration(border: InputBorder.none, hintText: "COMMAND IP")))),
                            IconButton(
                                icon: Icon(Icons.qr_code_scanner, color: kSciFiCyan, size: 20),
                                onPressed: _openQRScanner
                            ),
                            SciFiButton(label: "LINK", icon: Icons.link, color: primaryColor, onTap: _connect, isCompact: true)
                          ])
                        ]
                        else Padding(padding: const EdgeInsets.only(top: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text("ID: ${_idController.text.toUpperCase()}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 14)),
                          IconButton(icon: const Icon(Icons.link_off, color: kSciFiRed, size: 20), onPressed: _disconnect)
                        ]))
                      ]),
                    ),
                  ),

                  // THE HANDLE / TAB
                  GestureDetector(
                    onTap: () => setState(() => _isTopPanelVisible = !_isTopPanelVisible),
                    child: Container(
                      width: 100, height: 25,
                      decoration: BoxDecoration(
                          color: kSciFiDarkBlue.withOpacity(0.9),
                          border: Border(
                            bottom: BorderSide(color: primaryColor),
                            left: BorderSide(color: primaryColor),
                            right: BorderSide(color: primaryColor),
                          ),
                          borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12))
                      ),
                      child: Icon(_isTopPanelVisible ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: primaryColor, size: 20),
                    ),
                  ),

                  if (_pendingOrder != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                      child: SciFiPanel(
                        borderColor: widget.isStealth ? kSciFiRed : kSciFiGreen,
                        title: "INCOMING ORDER // ${_pendingOrder!['sender']}",
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_pendingOrder!['content'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, fontFamily: 'Courier')),
                          const SizedBox(height: 8),
                          SciFiButton(label: "ACKNOWLEDGE", icon: Icons.check_circle, color: Colors.white, onTap: _acknowledgeOrder)
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // --- COMPASS & RECENTER BUTTON (BOTTOM RIGHT) ---
          Positioned(
              bottom: 300,
              right: 16,
              child: SciFiCompass(
                color: primaryColor,
                onRecenterLocation: () {
                  if (_hasFix) {
                    _mapController.move(_myLocation, 17);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("CENTERED"), duration: Duration(milliseconds: 500)));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("WAITING FOR GPS FIX...")));
                  }
                },
                onResetNorth: () {
                  _mapController.rotate(0.0);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("NORTH RESET"), duration: Duration(milliseconds: 500)));
                },
                onRotate: (angle) {
                  _mapController.rotate(angle);
                },
              )
          ),

          // --- UI BUTTONS (BOTTOM) ---
          SafeArea(
            child: Column(
              children: [
                const Spacer(),

                // --- MEDIC ROLE ADJUSTMENT ---
                if (_selectedRole == "MEDIC")
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                    child: SizedBox(
                      width: double.infinity,
                      child: SciFiButton(label: "OPEN BIO-SCANNER", icon: Icons.monitor_heart, color: kSciFiGreen, onTap: _openBioScanner),
                    ),
                  ),

                // --- BLACK BOX & BURN BAG BUTTONS ---
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    children: [
                      Expanded(
                          child: Container(
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                                border: Border.all(color: _isBlackBoxActive ? Colors.redAccent : Colors.grey),
                                color: _isBlackBoxActive ? Colors.red.withOpacity(0.2) : null,
                                borderRadius: BorderRadius.circular(4)
                            ),
                            child: TextButton.icon(
                                onPressed: _triggerBlackBox,
                                icon: Icon(
                                    _isBlackBoxActive ? Icons.stop_circle : Icons.fiber_manual_record,
                                    size: 16,
                                    color: _isBlackBoxActive ? Colors.redAccent : Colors.grey
                                ),
                                label: Text(
                                    _isBlackBoxActive ? "REC ($_blackBoxRecordingTime s)" : "BLACK BOX",
                                    style: TextStyle(color: _isBlackBoxActive ? Colors.white : Colors.grey, fontSize: 10)
                                )
                            ),
                          )
                      ),
                      Expanded(
                          child: Container(
                            margin: const EdgeInsets.only(left: 4),
                            decoration: BoxDecoration(border: Border.all(color: Colors.red), borderRadius: BorderRadius.circular(4)),
                            child: TextButton.icon(
                                onPressed: _triggerBurnBag,
                                icon: Icon(Icons.delete_forever, size: 16, color: Colors.red),
                                label: Text("BURN BAG", style: TextStyle(color: Colors.red, fontSize: 10))
                            ),
                          )
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SciFiPanel(
                    showBg: true,
                    borderColor: primaryColor,
                    child: Column(children: [
                      Row(children: [
                        if (_selectedRole != "MEDIC")
                          Expanded(child: SciFiButton(label: "BIO", icon: Icons.monitor_heart, color: _isBioActive ? kSciFiRed : Colors.grey, onTap: _openBioScanner, isCompact: true)),
                        if (_selectedRole != "MEDIC") const SizedBox(width: 4),

                        Expanded(child: SciFiButton(label: "AR", icon: Icons.view_in_ar, color: kSciFiCyan, onTap: _openAR, isCompact: true)),
                        const SizedBox(width: 4),
                        Expanded(child: SciFiButton(label: "CAM", icon: Icons.camera_alt, color: Colors.purpleAccent, onTap: _sendTacticalImage, isCompact: true)),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(child: SciFiButton(label: "SITREP", icon: Icons.assignment, color: Colors.blue, onTap: _sendSitrep, isCompact: true)),
                        const SizedBox(width: 4),
                        Expanded(child: SciFiButton(label: "LOGS", icon: _hasUnread ? Icons.mark_email_unread : Icons.history, color: _hasUnread ? kSciFiGreen : Colors.white, onTap: _showLogs, isCompact: true)),
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
        ],
      ),
    );
  }
}

// --- EKG PAINTER ---
class EkgPainter extends CustomPainter {
  final double animationValue;
  final Color color;
  EkgPainter({required this.animationValue, required this.color});
  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final path = Path(); // Using dart:ui Path
    final width = size.width; final height = size.height; final mid = height / 2;
    for (double x = 0; x <= width; x++) {
      double offset = (x / width) + animationValue;
      double y = mid + sin(offset * pi * 10) * (height / 3); // Using direct math functions
      if ((offset * 5) % 1 > 0.9) { y -= height / 2; }
      if (x == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }
  @override bool shouldRepaint(covariant EkgPainter oldDelegate) => true;
}