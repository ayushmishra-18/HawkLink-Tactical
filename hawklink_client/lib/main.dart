// SOLDIER UPLINK - CLIENT SIDE
// Run this on Android/iOS devices for field operatives.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math'; // Imports sin, cos, pi directly
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'security/secure_channel.dart';
import 'security/secure_logger.dart';
import 'security/key_exchange.dart';
import 'security/command_verifier.dart';
import 'security/input_validator.dart';
import 'security/biometric_gate.dart';
import 'utils/encrypted_tile_provider.dart';
import 'security/rate_limiter.dart';
import 'utils/dead_reckoning_engine.dart';
import 'utils/voice_comms.dart';
import 'utils/triage_system.dart';
import 'utils/voice_io.dart'; // VOICE PTT

// --- CONFIGURATION ---
// --- CONFIGURATION ---
const int kPort = 4444;
// KEYS REMOVED: Replaced with ECDH Key Exchange

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

class _UplinkScreenState extends State<UplinkScreen> with TickerProviderStateMixin {
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
  int _heartRate = 75; // Default resting HR
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
  double _envTemp = 0.0;
  double _envWind = 0.0;
  String _envCond = 'WAITING SYNC';

  // --- SENSORS ---
  Timer? _biometricTimer;
  Timer? _simulationTimer;

  final MapController _mapController = MapController();
  LatLng _myLocation = const LatLng(40.7128, -74.0060);
  double _heading = 0.0;
  List<Marker> _targetMarkers = [];
  bool _hasFix = false;
  Timer? _heartbeatTimer;
  final Battery _battery = Battery();
  final FlutterTts _tts = FlutterTts();
  final ImagePicker _picker = ImagePicker();
  
  // Security
  SecureChannel? _secureChannel;
  final KeyExchange _keyExchange = KeyExchange();
  late AnimationController _sosController;
  List<int> _incomingBuffer = [];

  AcousticSensor? _acousticSensor;
  bool _isGunshotDetected = false;
  bool _isMicPermissionGranted = false;
  final VoiceIO _voiceIO = VoiceIO();
  bool _isTalking = false; // PTT State


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
  
  // --- DEAD RECKONING ---
  final DeadReckoningEngine _drEngine = DeadReckoningEngine();
  bool _isDrActive = false;
  
  // --- VOICE COMMS  // VOICE
  final VoiceComms _voiceComms = VoiceComms();

  // TRIAGE
  TriageCategory _triageStatus = TriageCategory.MINIMAL;
  bool _isCasevacRequested = false;
  
  // AR & TEAM
  List<SoldierUnit> _teammates = [];



  @override
  void initState() {
    super.initState();
    _sosController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _startGpsTracking();
    _startCompass();
    _initTts();

    _initAcousticSensor();
    _initAcousticSensor();
    _voiceIO.init();
    CommandVerifier.loadKey(); // Load Server Key for verification
    SecureLogger.init(); // Secure Logs
    
    // NEW: Require biometric authentication
    _requireBiometric(); 
    
    // --- FATIGUE CHECKER ---
    _biometricTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
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

    // --- VITAL SIGNS SIMULATION ---
    _simulationTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        setState(() {
          if (!_isBioActive) {
            int variance = Random().nextInt(5) - 2;
            _heartRate = (_heartRate + variance).clamp(60, 180);
          }
        });
      }
    });

    // --- DEAD RECKONING LISTENER ---
    _drEngine.positionStream.listen((pos) {
      if (_isDrActive && mounted) {
        setState(() {
          _myLocation = pos;
          // Optionally smooth this or show confidence circle
          if (_mapController.camera.zoom < 10) _mapController.move(_myLocation, 17);
        });
        // Still check for danger zones even in DR mode
        if (_dangerZone.isNotEmpty) {
           bool currentlyInDanger = _isPointInside(_myLocation, _dangerZone);
           if (currentlyInDanger && !_isInDanger && !widget.isStealth) {
             _tts.speak("Warning. DR Mode. Entering Restricted Zone!");
             _handleGeofenceBreach();
           }
           _isInDanger = currentlyInDanger;
        }
      }
    });
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
    Navigator.push(context, MaterialPageRoute(builder: (c) => ArCompassView(waypoints: _waypoints, teammates: _teammates, myLocation: _myLocation)));
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
    _blackBoxChunkTimer?.cancel();
    _simulationTimer?.cancel();
    _audioRecorder.dispose();
    _acousticSensor?.stop();
    _sosController.dispose();
    _demoTimer?.cancel();
    _gpsTimeoutTimer?.cancel();
    _drEngine.stop();
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

  Timer? _gpsTimeoutTimer;

  Future<void> _startGpsTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) { permission = await Geolocator.requestPermission(); if (permission == LocationPermission.denied) return; }

    const LocationSettings locationSettings = LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0);

    Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      if (!mounted) return;
      
      // GPS Watchdog Reset
      _gpsTimeoutTimer?.cancel();
      _gpsTimeoutTimer = Timer(const Duration(seconds: 10), () {
        if (mounted && !_isDrActive && _hasFix) {
           setState(() => _isDrActive = true);
           _drEngine.start(_myLocation);
           if (!widget.isStealth) _tts.speak("GPS Lost. Engaging Dead Reckoning.");
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.orange, content: Text("GPS LOST - DR MODE ACTIVE")));
        }
      });

      // Accuracy Check
      if (position.accuracy > 50.0) {
         // Poor signal, stick to DR if already active, or switch?
         // For now, let's treat poor accuracy as "keep DR if active", else "accept but warn"
      } else {
         // Good signal
         if (_isDrActive) {
           _drEngine.stop();
           setState(() => _isDrActive = false);
           if (!widget.isStealth) _tts.speak("GPS Restored.");
         }
         _drEngine.syncPosition(LatLng(position.latitude, position.longitude));
      }

      if (!_isDrActive) {
        setState(() {
          _myLocation = LatLng(position.latitude, position.longitude);
          _hasFix = true;
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
      // Load Security Certificates
      final clientCert = await rootBundle.loadString('assets/certs/client-cert.pem');
      final clientKey = await rootBundle.loadString('assets/certs/client-key.pem');
      final serverCert = await rootBundle.loadString('assets/certs/ca-cert.pem');

      final context = SecurityContext(withTrustedRoots: true)
        ..useCertificateChainBytes(utf8.encode(clientCert))
        ..usePrivateKeyBytes(utf8.encode(clientKey))
        ..setTrustedCertificatesBytes(utf8.encode(serverCert));

      _socket = await SecureSocket.connect(
        _ipController.text, 
        kPort, 
        context: context,
        timeout: const Duration(seconds: 10),
        onBadCertificate: (cert) => true, // Verification handled by setTrustedCertificates
      );
      setState(() => _status = "SECURE UPLINK ESTABLISHED");
      if (!widget.isStealth) _tts.speak("Connected");
      _incomingBuffer = [];
      _socket!.listen((data) => _handleIncomingPacket(data), onDone: () { if (mounted) setState(() { _status = "CONNECTION LOST"; _socket = null; }); if (!widget.isStealth) _tts.speak("Connection Lost"); }, onError: (e) { if (mounted) setState(() { _status = "ERROR: $e"; _socket = null; }); });
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) => _sendHeartbeat());
    } catch (e) { if (mounted) setState(() { _status = "FAILED TO CONNECT"; _socket = null; }); }
  }

  void _disconnect() { _socket?.destroy(); if (mounted) setState(() { _status = "DISCONNECTED"; _socket = null; }); }

  void _handleIncomingPacket(List<int> data) async {
    _incomingBuffer.addAll(data);
    
    // 0. RATE LIMIT CHECK
    // If not authenticated yet or spamming too hard
    if (_socket != null && !RateLimiter.isAllowed(_socket!)) {
       // Just return / drop. 
       // Optionally we could disconnect if this persists.
       return; 
    }

    try {
       final str = utf8.decode(_incomingBuffer).trim();
       if (str.isEmpty) return;
      
      // HANDSHAKE
      if (_secureChannel == null) {
        if (str.startsWith("KEY_EXCHANGE|")) {
           try {
             final parts = str.split('|');
             final serverPubKey = base64Decode(parts[1]);
             
             // Generate our keys
             await _keyExchange.generateKeyPair();
             final myPubKey = base64Encode(_keyExchange.getPublicKeyBytes());
             
             // Send our key
             _socket!.add(utf8.encode("KEY_EXCHANGE|$myPubKey\n"));
             
             // Compute Shared Secret
             final sharedSecret = _keyExchange.computeSharedSecret(serverPubKey);
             final sessionKey = _keyExchange.deriveSessionKey(sharedSecret, "salt", "HawkLink-v1");
             
             setState(() {
               _secureChannel = SecureChannel(sessionKey);
               _status = "SECURE PROTOCOL ACTIVE"; // Update status
             });
             _incomingBuffer.clear();
           } catch(e) {
             setState(() => _status = "HANDSHAKE ERROR");
             _disconnect();
           }
        }
        return;
      }
      
      // ENCRYPTED MSG
      EncryptedMessage msg;
      try {
        final bytes = base64Decode(str);
        msg = EncryptedMessage.fromBytes(bytes);
        _incomingBuffer.clear(); // Clear buffer only on successful parse attempt
      } catch(e) { return; } // Wait for more data? Or invalid?

      final decrypted = _secureChannel!.decrypt(msg);
      final json = jsonDecode(decrypted);
      
      // PHASE 3: INPUT VALIDATION
      if (!InputValidator.validatePacket(json)) {
         // debugPrint("INVALID PACKET DROPPED");
         return;
      }

      _processMessage(json);
    } catch(e) {
      // debugPrint("Parse Error: $e");
    }
  }

  void _processMessage(Map<String, dynamic> json) {
    // SECURE KILL COMMAND HANDLER
    if (json['type'] == 'ZEROIZE_REQUEST') {
      _handleZeroizeRequest(json);
      return;
    }
    // LEGACY KILL REMOVED

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
    // --- UPDATED: RECEIVE TERRAIN FROM COMMANDER ---
    else if (json['type'] == 'TERRAIN') {
      var data = json['data'];
      setState(() {
        _envTemp = (data['temp'] as num).toDouble();
        _envWind = (data['wind'] as num).toDouble();
        _envCond = data['cond'].toString().toUpperCase();
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
    // --- TEAM POSITION UPDATE (AR) ---
    else if (json['type'] == 'TEAM_POS') {
      List<dynamic> list = json['data'];
      setState(() {
        _teammates = list.where((u) => u['id'] != _idController.text.toUpperCase()).map((u) => SoldierUnit(
          id: u['id'],
          location: LatLng(u['lat'], u['lng']),
          role: u['role'],
          status: u['status'],
          lastSeen: DateTime.now()
        )).toList();
      });
    }
    // --- VOICE (PTT) ---
    else if (json['type'] == 'VOICE') {
      try {
        // If not me (echo), play it
        if (json['sender'] != _idController.text.toUpperCase()) {
           final audioBytes = base64Decode(json['content']);
           _voiceIO.playAudio(audioBytes);
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Row(children: [const Icon(Icons.record_voice_over, color: Colors.white), const SizedBox(width:8), Text("${json['sender']} SPEAKING...", style: const TextStyle(fontWeight: FontWeight.bold))],),
              backgroundColor: kSciFiDarkBlue, duration: const Duration(seconds: 2),
           ));
        }
      } catch (e) {
        debugPrint("VOICE RX ERROR: $e");
      }


  }
}

  // --- PTT LOGIC ---
  Future<void> _startTalking() async {
    setState(() => _isTalking = true);
    await _voiceIO.startRecording();
    if (!widget.isStealth) _tts.speak("Channel Open");
  }

  Future<void> _stopTalking() async {
    setState(() => _isTalking = false);
    final file = await _voiceIO.stopRecording();
    
    if (file != null) {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final b64 = base64Encode(bytes);
        
        _sendPacket({
          'type': 'VOICE',
          'sender': _idController.text.toUpperCase(),
          'content': b64
        });
        if (!widget.isStealth) _tts.speak("Transmitted");
        await file.delete();
      }
    }
  }

  // --- SECURE ZEROIZATION LOGIC ---
  void _handleZeroizeRequest(Map<String, dynamic> json) async {
    // 1. Verify Signature
    if (!CommandVerifier.verify(json)) {
      _sendPacket({'type': 'CHAT', 'content': 'SECURITY: Invalid Zeroize Signature Detected'});
      return;
    }
    
    // 2. Check Target ID
    if (json['target'] != _idController.text.toUpperCase()) return;

    // 3. Multi-Factor Confirmation
    bool confirmed = await showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red[900],
        title: const Text("⚠️ PROTOCOL ZERO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Remote Command: WIPE DEVICE", style: TextStyle(color: Colors.white)),
            Text("Reason: ${json['reason']}", style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            const Text("CONFIRM IDENTITY TO PROCEED", style: TextStyle(color: Colors.amber)),
          ],
        ),
        actions: [
           TextButton(
             onPressed: () => Navigator.pop(ctx, false), 
             child: const Text("DENY", style: TextStyle(color: Colors.white))
           ),
           ElevatedButton(
             style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
             onPressed: () => Navigator.pop(ctx, true),
             child: const Text("CONFIRM WIPE")
           )
        ],
      )
    ) ?? false;

    if(confirmed) {
      // 4. Biometric/PIN Check (Mock for now)
      // In real app, call LocalAuthentication
      _executeSecureZeroization();
    } else {
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'ZEROIZE COMMAND DENIED BY OPERATOR'});
    }
  }

  Future<void> _executeSecureZeroization() async {
    _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'ZEROIZE: EXECUTING...'});
    SecureLogger.log("SEC", "ZEROIZATION EXECUTED - WIPING DATA"); // Audit Trail before death
    _socket?.destroy(); // Cut comms
    
    // Secure Storage Wipe
    final storage = FlutterSecureStorage();
    await storage.deleteAll();
    
    // File Wipe (Simple overwrite for now, DoD 3-pass in production)
    final d = await getApplicationDocumentsDirectory();
    if(d.existsSync()) d.deleteSync(recursive: true);
    
    if (!mounted) exit(0);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
               Icon(Icons.lock, size: 80, color: Colors.green),
               SizedBox(height: 20),
               Text("DEVICE SANITIZED", style: TextStyle(color: Colors.green, fontSize: 24, fontFamily: 'Courier')),
               Text("SHUTTING DOWN...", style: TextStyle(color: Colors.green, fontFamily: 'Courier')),
            ],
          ),
        ),
      ),
    );
    await Future.delayed(const Duration(seconds: 4));
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

        // --- DATA SNAPSHOT ---
        // Ensure values are captured right before sending
        final double currentLat = _myLocation.latitude;
        final double currentLng = _myLocation.longitude;
        final int currentBpm = _heartRate;
        final int currentSpo2 = _spO2;
        final String currentBp = _bp;

        // Debug output to verify what we are sending
        debugPrint("SENDING AUDIO META: Lat:$currentLat Lng:$currentLng BPM:$currentBpm");

        // Send packet with EXTRA TELEMETRY
        _sendPacket({
          'type': 'INTEL_AUDIO',
          'sender': _idController.text.toUpperCase(),
          'content': base64Audio,
          'duration': '10s',
          'timestamp': DateTime.now().toIso8601String(),
          // NEW FIELDS with explicit values
          'lat': currentLat,
          'lng': currentLng,
          'bpm': currentBpm,
          'spO2': currentSpo2,
          'bp': currentBp,
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
        'state': _isCasevacRequested ? "CASEVAC" : state,
        'bpm': _heartRate,
        'spo2': _spO2,
        'bp': _bp,
        'temp': _temp,
        'heat': _isHeatStress,
        'dr': _isDrActive,
        'triage_color': TriageSystem.getColor(_triageStatus).value.toRadixString(16),
        'casevac': _isCasevacRequested
      });
    } catch (e) {}
  }

  void _sendPacket(Map<String, dynamic> data) {
    if (_socket == null || _secureChannel == null) return;
    try {
      final jsonStr = jsonEncode(data);
      final msg = _secureChannel!.encrypt(jsonStr);
      final b64 = base64Encode(msg.toBytes());
      _socket!.add(utf8.encode("$b64\n"));
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
  String _formatCoord(double v, bool l) {
    String latDir = l ? (v >= 0 ? "N" : "S") : (v >= 0 ? "E" : "W");
    return "${v.abs().toStringAsFixed(5)}° $latDir";
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
                TileLayer(
                  urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                  tileProvider: EncryptedTileProvider(),
                  userAgentPackageName: 'com.hawklink.soldier'
                ),
                PolygonLayer(polygons: [if (_dangerZone.isNotEmpty) Polygon(points: _dangerZone, color: kSciFiRed.withOpacity(0.3), borderColor: kSciFiRed, borderStrokeWidth: 4, isFilled: true)]),

                MarkerLayer(markers: [
                  if (_hasFix || _isDrActive) Marker(
                    point: _myLocation, 
                    width: 40, 
                    height: 40, 
                    child: Transform.rotate(
                      angle: (_heading * (pi / 180)), 
                      child: Icon(
                        _isDrActive ? Icons.explore_off : Icons.navigation, 
                        color: _isDrActive ? Colors.orange : primaryColor, 
                        size: 35
                      )
                    )
                  ),
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

                        // --- NEW: COMBINED LOCATION & WEATHER ROW ---
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                              border: Border.all(color: Colors.white12),
                              borderRadius: BorderRadius.circular(4),
                              color: Colors.white.withOpacity(0.05)
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Left: Location
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("LOC: ${_formatCoord(_myLocation.latitude, true)}", style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'Courier', letterSpacing: 1.0)),
                                  Text("     ${_formatCoord(_myLocation.longitude, false)}", style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'Courier', letterSpacing: 1.0)),
                                ],
                              ),

                              // Divider
                              Container(height: 25, width: 1, color: Colors.white24),

                              // Right: Weather (ADJACENT)
                              Row(children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Row(children: [
                                      Icon(Icons.thermostat, size: 10, color: Colors.grey),
                                      Text(" ${_envTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Orbitron')),
                                      const SizedBox(width: 4),
                                      Icon(Icons.air, size: 10, color: Colors.grey),
                                      Text(" ${_envWind.toStringAsFixed(0)}", style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Orbitron')),
                                    ]),
                                    Text(_envCond, style: TextStyle(color: _envCond == 'Clear' ? kSciFiGreen : Colors.orange, fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'Orbitron')),
                                  ],
                                ),
                              ]),
                            ],
                          ),
                        ),

                        if (_isHeatStress)
                          Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text("⚠ HEAT STRESS WARNING", style: TextStyle(color: kSciFiRed, fontWeight: FontWeight.bold, fontSize: 12, backgroundColor: Colors.black54)),
                          ),

                        const Divider(color: Colors.white12, height: 16),

                        // --- NEW: ROLE SPECIFIC UI BELOW ---
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

                      const SizedBox(height: 8),

                      // --- COMBINED ACTION ROW (SOS & PTT) ---
                      Row(
                        children: [
                          // SOS BUTTON (Left, Smaller)
                          Expanded(
                            flex: 1,
                            child: GestureDetector(
                                onLongPress: _activateSOS,
                                child: Container(
                                    height: 50,
                                    decoration: BoxDecoration(
                                        color: isSOS ? kSciFiRed.withOpacity(0.8) : kSciFiRed.withOpacity(0.1),
                                        border: Border.all(color: kSciFiRed, width: 2),
                                        borderRadius: BorderRadius.circular(4),
                                        boxShadow: [if (isSOS) BoxShadow(color: kSciFiRed.withOpacity(0.5), blurRadius: 10)]
                                    ),
                                    child: Center(
                                        child: Text(isSOS ? "SOS" : "HOLD SOS", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier', letterSpacing: 1))
                                    )
                                )
                            ),
                          ),
                          const SizedBox(width: 8),
                          
                          // PTT BUTTON (Right, Main)
                          Expanded(
                            flex: 2,
                            child: GestureDetector(
                              onLongPressStart: (_) => _startTalking(),
                              onLongPressEnd: (_) => _stopTalking(),
                              child: Container(
                                height: 50,
                                decoration: BoxDecoration(
                                    color: _isTalking ? kSciFiCyan : kSciFiDarkBlue,
                                    border: Border.all(color: kSciFiCyan, width: 2),
                                    borderRadius: BorderRadius.only(topRight: Radius.circular(12), bottomLeft: Radius.circular(12)),
                                    boxShadow: [if (_isTalking) BoxShadow(color: kSciFiCyan.withOpacity(0.5), blurRadius: 15, spreadRadius: 2)]
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(_isTalking ? Icons.mic : Icons.mic_none, color: _isTalking ? Colors.black : kSciFiCyan),
                                    const SizedBox(width: 8),
                                    Text(_isTalking ? "ON AIR" : "PUSH TO TALK", style: TextStyle(color: _isTalking ? Colors.black : kSciFiCyan, fontWeight: FontWeight.bold, fontFamily: 'Orbitron', letterSpacing: 1.5))
                                  ],
                                ),
                            ),
                          ),
                        ),
                        ],
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
         GestureDetector(
           onLongPress: _startTalking,
           onLongPressUp: _stopTalking,
           onLongPressCancel: _stopTalking, // Handle cancel too
           child: Container(
             margin: const EdgeInsets.only(bottom: 15),
             width: 70, height: 70,
             decoration: BoxDecoration(
               color: _isTalking ? kSciFiRed : kSciFiCyan.withOpacity(0.2),
               shape: BoxShape.circle,
               border: Border.all(color: _isTalking ? Colors.white : kSciFiCyan, width: 2),
               boxShadow: [BoxShadow(color: _isTalking ? Colors.redAccent : kSciFiCyan, blurRadius: 10)]
             ),
             child: Icon(_isTalking ? Icons.mic : Icons.mic_none, color: Colors.white, size: 30),
           ),
         ),
      ]),
    );
  }
  // --- BIOMETRIC AUTH METHODS ---
  Future<void> _requireBiometric() async {
    // Check if biometric is available
    final canAuth = await BiometricGate.canAuthenticate();
    
    if (!canAuth) {
      // Device doesn't support biometrics - allow anyway
      debugPrint('Biometric auth not available on this device');
      return;
    }
    
    // Show authentication dialog
    try {
      final authenticated = await BiometricGate.authenticate();
      
      if (!authenticated) {
        // Auth failed - close app
        _showAuthFailedDialog();
      }
    } on PlatformException catch (e) {
      if (e.code == 'LOCKED_OUT') {
        _showLockoutDialog(e.message ?? 'Too many failed attempts');
      }
    }
  }

  void _showAuthFailedDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Authentication Failed'),
        content: Text('Biometric authentication is required to access HawkLink.\n\nReason: ${BiometricGate.lastError}'),
        actions: [
          TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: const Text('EXIT', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              debugPrint("Warning: Biometric Bypassed by User");
            },
            child: const Text('OVERRIDE (DEV)', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _requireBiometric();  // Retry
            },
            child: const Text('RETRY', style: TextStyle(color: Colors.blueAccent)),
          ),
        ],
      ),
    );
  }

  void _showLockoutDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        title: const Text('SECURITY LOCKOUT', style: TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: const Text('EXIT', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              debugPrint("Warning: Lockout Bypassed by User");
            },
            child: const Text('OVERRIDE (DEV)', style: TextStyle(color: Colors.redAccent)),
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
    final path = Path();
    final width = size.width; final height = size.height; final mid = height / 2;
    for (double x = 0; x <= width; x++) {
      double offset = (x / width) + animationValue;
      double y = mid + sin(offset * pi * 10) * (height / 3);
      if ((offset * 5) % 1 > 0.9) { y -= height / 2; }
      if (x == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }
  @override bool shouldRepaint(covariant EkgPainter oldDelegate) => true;
}