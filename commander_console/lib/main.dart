// COMMANDER CONSOLE - SERVER SIDE
// Run this on the Laptop or Tablet acting as the Command Center.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'utils/secure_image_thumbnail.dart';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:intl/intl.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:http/http.dart' as http;
import 'sci_fi_ui.dart';
import 'security/secure_channel.dart';
import 'utils/encrypted_tile_provider.dart';
import 'security/key_exchange.dart';
import 'security/key_exchange.dart';
import 'security/command_signer.dart';
import 'security/input_validator.dart';
import 'security/secure_logger.dart';
import 'security/rate_limiter.dart';
import 'utils/voice_receiver.dart';
import 'utils/formation_advisor.dart'; // AI ADVISOR
import 'utils/voice_receiver.dart'; // VOICE PLAYER
import 'models.dart'; // SHARED MODELS

// --- CONFIGURATION ---
const int kPort = 4444;
// KEYS REMOVED: Replaced with ECDH Key Exchange

// --- HARDENING CONSTANTS (Top Level) ---
const int kSignalWarning = 5;
const int kSignalLost = 15;

// --- DATA MODELS ---

void main() { runApp(const CommanderApp()); }

class CommanderApp extends StatelessWidget {
  const CommanderApp({super.key});
  @override Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kSciFiBlack,
        colorScheme: const ColorScheme.dark(primary: kSciFiCyan, surface: kSciFiDarkBlue),
        textTheme: const TextTheme(bodyMedium: TextStyle(fontFamily: 'Courier')),
      ),
      home: const CommanderDashboard(),
    );
  }
}

class CommanderDashboard extends StatefulWidget {
  const CommanderDashboard({super.key});
  @override State<CommanderDashboard> createState() => _CommanderDashboardState();
}

class _CommanderDashboardState extends State<CommanderDashboard> with TickerProviderStateMixin {
  dynamic _server; // Changed from ServerSocket? to allow SecureServerSocket assignment
  final List<SoldierUnit> _units = [];

  // LOGS structure: {text: String, image: String?, audio: String?, meta: Map<String, dynamic>?}
  final List<Map<String, dynamic>> _logs = [];

  final List<TacticalWaypoint> _waypoints = [];
  List<String> _myIps = [];
  TerrainData _terrain = TerrainData();
  
  // VOICE
  final VoiceReceiver _voiceReceiver = VoiceReceiver();

  final TextEditingController _cmdController = TextEditingController();
  final Map<Socket, List<int>> _clientBuffers = {};

  // Audio
  final AudioPlayer _sfxPlayer = AudioPlayer();
  final AudioPlayer _alertPlayer = AudioPlayer();
  final AudioPlayer _intelPlayer = AudioPlayer(); // Player for Black Box audio
  String? _currentlyPlayingPath; // Track what is playing
  bool _audioEnabled = true;

  // Encryption
  // Security
  final Map<Socket, SecureChannel> _secureChannels = {};
  final Map<Socket, KeyExchange> _keyExchanges = {};
  final Map<Socket, bool> _handshakeComplete = {};

  // Visuals
  final MapController _mapController = MapController();
  late AnimationController _pulseController;
  late AnimationController _ekgController;

  // Logic
  Timer? _watchdogTimer;
  String? _selectedUnitId;
  bool _showGrid = true;
  bool _showTrails = true;
  bool _showRangeRings = true;
  bool _showTacticalMatrix = false;
  bool _showCasualtyBoard = false;
  double _tilt = 0.0;
  double _rotation = 0.0;
  bool _isDrawingMode = false;
  String? _placingWaypointType;
  bool _isDeleteWaypointMode = false;
  List<LatLng> _tempDrawPoints = [];
  List<LatLng> _activeDangerZone = [];
  bool _isMeasureMode = false;
  List<LatLng> _measurePoints = [];
  bool _isWeatherUpdating = false; // Loading state for weather button


  // Default Map Center (Hyderabad for testing)
  LatLng _mapCenter = const LatLng(17.3850, 78.4867);

  @override
  void initState() {
    super.initState();
    _startServer();
    _getLocalIps();
    CommandSigner.loadKey(); // Load RSA Key
    SecureLogger.init(); // Init encrypted logging
    _loadSecureLogs();

    // Initial weather fetch for default location
    _fetchWeatherForLocation(_mapCenter);

    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
    _ekgController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), _checkNetworkHealth);
    
    // NEW: TEAM POSITION BROADCAST TIMER (Every 3s)
    Timer.periodic(const Duration(seconds: 3), (t) => _broadcastTeamPositions());

    // SFX Init
    _sfxPlayer.setReleaseMode(ReleaseMode.stop);
    _alertPlayer.setReleaseMode(ReleaseMode.stop);
    _intelPlayer.setReleaseMode(ReleaseMode.stop);

    // Listen to player state to update UI
    _intelPlayer.onPlayerComplete.listen((event) {
      setState(() {
        _currentlyPlayingPath = null;
      });
    });
  }

  @override
  void dispose() {
    _server?.close();
    _watchdogTimer?.cancel();
    _sfxPlayer.dispose();
    _alertPlayer.dispose();
    _intelPlayer.dispose();
    _pulseController.dispose();
    _ekgController.dispose();
    super.dispose();
  }

  // --- LOGIC METHODS ---

  // NEW: Fetch Real Weather for Commander View
  Future<void> _fetchWeatherForLocation(LatLng loc) async {
    setState(() => _isWeatherUpdating = true);
    try {
      // Fetching weather...
      final url = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${loc.latitude}&longitude=${loc.longitude}&current_weather=true');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final current = data['current_weather'];

        setState(() {
          _terrain.temperature = (current['temperature'] as num).toDouble();
          _terrain.windSpeed = (current['windspeed'] as num).toDouble();

          // Map WMO code to condition string
          // Simplified mapping
          int code = current['weathercode'];
          if (code == 0) _terrain.condition = 'Clear';
          else if (code < 3) _terrain.condition = 'Cloudy';
          else if (code < 50) _terrain.condition = 'Foggy';
          else if (code < 80) _terrain.condition = 'Rainy';
          else _terrain.condition = 'Storm';

          _isWeatherUpdating = false;
        });

        _log("SYS", "WEATHER UPDATED: ${_terrain.temperature}°C, ${_terrain.condition}");
        _broadcastTerrain(); // Auto-sync with soldiers
      } else {
        setState(() => _isWeatherUpdating = false);
      }
    } catch (e) {
      debugPrint("Weather Error: $e");
      _log("SYS", "WEATHER FETCH FAILED");
      setState(() => _isWeatherUpdating = false);
    }
  }

  void _broadcastTerrain() {
    for(var u in _units) _sendToSocket(u.socket, {
      'type': 'TERRAIN',
      'sender': 'COMMAND',
      'data': _terrain.toJson()
    });
  }

  void _checkNetworkHealth(Timer t) {
    bool needsRebuild = false;
    for (var u in _units) {
      if (u.status == "KILLED") continue;
      int silence = u.secondsSincePing;
      if (silence > kSignalLost && u.status != "LOST") { u.status = "LOST"; _log("NET", "⚠️ SIGNAL LOST: ${u.id}"); _playAlert('alert.mp3'); needsRebuild = true; }
      if (silence > 0) needsRebuild = true;
    }
    if (needsRebuild) setState(() {});
  }

  void _checkGeofences(SoldierUnit u) {
    if (_activeDangerZone.length < 3) return;
    bool isInside = _isPointInside(u.location, _activeDangerZone);
    if (isInside && !u.inDangerZone) {
      u.inDangerZone = true;
      _log("TAC", "⚠️ ALERT: ${u.id} BREACHED DANGER ZONE");
      _playAlert('alert.mp3');
      if (u.socket != null) {
        _sendToSocket(u.socket, {'type': 'BREACH', 'sender': 'COMMAND', 'content': '!!! YOU HAVE ENTERED A DANGER ZONE !!!'});
      }
    } else if (!isInside && u.inDangerZone) {
      u.inDangerZone = false;
      _log("TAC", "${u.id} EXITED DANGER ZONE");
    }
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

  void _showQuickJoinQR() {
    if (_myIps.isEmpty) return;
    String qrData = "${_myIps.first}|$kPort"; // Replaced PSK with Port
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
            backgroundColor: Colors.black87,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: kSciFiCyan)),
            title: const Text("QUICK JOIN // UPLINK", style: TextStyle(color: kSciFiCyan, fontFamily: 'Orbitron')),
            content: SizedBox(
              width: 220,
              height: 220,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 200.0,
                    backgroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CLOSE", style: TextStyle(color: kSciFiRed)))]
        )
    );
  }

  void _sendKillCommand(SoldierUnit u) { 
    final timestamp = DateTime.now().toIso8601String();
    final cmd = {
      'type': 'ZEROIZE_REQUEST', // changed from KILL
      'target': u.id,
      'timestamp': timestamp,
      'reason': 'COMMANDER_INITIATED'
    };
    
    final sig = CommandSigner.sign(cmd);
    if(sig == null) { _log("SYS", "ERROR: CANNOT SIGN KILL CMD"); return; }
    
    cmd['signature'] = sig;
    
    _sendToSocket(u.socket, cmd);
    _log("CMD", "ZEROIZE REQUEST SENT: ${u.id}");
    
    // Don't mark as KILLED instantly; wait for confirmation or timeout
    setState(() => u.status = "ZEROIZING..."); 
  }
  void _broadcastTeamPositions() {
    if (_units.isEmpty) return;
    
    List<Map<String, dynamic>> teamData = _units.map((u) => {
      'id': u.id,
      'lat': u.location.latitude,
      'lng': u.location.longitude,
      'role': u.role,
      'status': u.status
    }).toList();

    for (var u in _units) {
      _sendToSocket(u.socket, {
        'type': 'TEAM_POS',
        'data': teamData
      });
    }
  }

  Future<void> _playSfx(String f) async { if(!_audioEnabled) return; try{ await _sfxPlayer.play(AssetSource('sounds/$f')); }catch(e){} }
  Future<void> _playAlert(String f) async { if(!_audioEnabled) return; try{ await _alertPlayer.play(AssetSource('sounds/$f')); }catch(e){} }

  // --- AUDIO LOGIC ---
  Future<void> _playAudioLog(String path) async {
    try {
      if (_currentlyPlayingPath == path) {
        await _intelPlayer.stop();
        setState(() => _currentlyPlayingPath = null);
      } else {
        await _intelPlayer.stop();
        
        Source source;
        if (path.endsWith('.enc')) {
           final file = File(path);
           if (await file.exists()) {
              final encrypted = await file.readAsBytes();
              final decrypted = await SecureLogger.decryptData(encrypted);
              source = BytesSource(decrypted);
           } else { 
              debugPrint("Audio file not found: $path");
              return; 
           }
        } else {
           source = DeviceFileSource(path);
        }

        await _intelPlayer.play(source);
        setState(() => _currentlyPlayingPath = path);
      }
    } catch(e) {
      debugPrint("Error playing audio: $e");
    }
  }

  Future<File> _getLogFile() async { final d = await getApplicationDocumentsDirectory(); return File('${d.path}/hawklink_logs.txt'); }
  Future<void> _loadLogs() async { try{ final f=await _getLogFile(); if(await f.exists()){ final c=await f.readAsLines(); setState(() { for(var l in c.reversed.take(100)) _logs.add({'text':l, 'image':null, 'audio': null}); }); } }catch(e){} }
  Future<void> _saveLog(String l) async { try{ final f=await _getLogFile(); await f.writeAsString('$l\n', mode: FileMode.append); }catch(e){} }

  Future<String> _saveImageToDisk(String s, String b64) async {
    try {
      final d = await getApplicationDocumentsDirectory();
      final i = Directory('${d.path}/HawkLink_Intel/Images');
      if (!await i.exists()) await i.create(recursive: true);
      
      String ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      File f = File('${i.path}/IMG_${s}_$ts.enc'); // Changed to .enc
      
      final bytes = base64Decode(b64);
      final encrypted = await SecureLogger.encryptData(bytes);
      await f.writeAsBytes(encrypted);
      
      return f.path;
    } catch(e) { return ""; }
  }

  // --- NEW: SAVE AUDIO + METADATA ---
  Future<String> _saveAudioToDisk(String s, String b64, Map<String, dynamic> metadata) async {
    try {
      final d = await getApplicationDocumentsDirectory();
      final audioDir = Directory('${d.path}/HawkLink_Intel/Audio');
      if (!await audioDir.exists()) await audioDir.create(recursive: true);

      String ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      String baseName = "AUDIO_${s}_$ts";

      // Save Audio Encrypted
      File f = File('${audioDir.path}/$baseName.enc'); // Changed to .enc
      final bytes = base64Decode(b64);
      final encrypted = await SecureLogger.encryptData(bytes);
      await f.writeAsBytes(encrypted);

      // Save Metadata (BPM, Location, etc.) - Leaving JSON plaintext for now for indexing
      File metaFile = File('${audioDir.path}/$baseName.json');
      await metaFile.writeAsString(jsonEncode(metadata));

      return f.path;
    } catch (e) {
      debugPrint("Audio Save Error: $e");
      return "";
    }
  }

  Future<void> _getLocalIps() async { try{ final i=await NetworkInterface.list(type: InternetAddressType.IPv4); setState(()=>_myIps=i.map((x)=>x.addresses.map((y)=>y.address).join(", ")).toList()); }catch(e){} }
  Future<void> _startServer() async {
    try {
      final context = SecurityContext(withTrustedRoots: true)
        ..useCertificateChain('certs/server-cert.pem')
        ..usePrivateKey('certs/server-key.pem')
        // TRUST THE CLIENT CERT DIRECTLY (P2P Trust)
        ..setTrustedCertificates('certs/client-cert.pem');
        
      _server = await SecureServerSocket.bind(
        InternetAddress.anyIPv4, 
        kPort, 
        context,
        requestClientCertificate: true, 
        requireClientCertificate: true
      );
      
      _server!.listen((c) {
        _log("SEC", "ENCRYPTED CONNECTION: ${c.remoteAddress.address}");
        _clientBuffers[c] = [];
        c.listen(
          (d) => _handleData(c, d),
          onError: (e) => _removeClient(c),
          onDone: () => _removeClient(c)
        );
        _initiateHandshake(c);
      });
    } catch (e) {
      _log("SYS", "SERVER ERROR: $e");
    }
  }
  void _removeClient(Socket c) { setState(() { for(var u in _units) { if(u.socket == c) u.socket = null; } _clientBuffers.remove(c); _secureChannels.remove(c); _keyExchanges.remove(c); }); }
  void _handleData(Socket c, List<int> d) { if(!_clientBuffers.containsKey(c)) _clientBuffers[c]=[]; _clientBuffers[c]!.addAll(d); List<int> b=_clientBuffers[c]!; while(true){ int i=b.indexOf(10); if(i==-1) break; List<int> p=b.sublist(0,i); b=b.sublist(i+1); _clientBuffers[c]=b; _processPacket(c,p); } }

  // --- SECURITY HANDSHAKE ---
  void _initiateHandshake(Socket c) async {
    final ke = KeyExchange();
    _keyExchanges[c] = ke;
    await ke.generateKeyPair();
    final pubKey = base64Encode(ke.getPublicKeyBytes());
    c.add(utf8.encode("KEY_EXCHANGE|$pubKey\n"));
    _log("SEC", "HANDSHAKE INIT: ${c.remoteAddress.address}");
  }

  // --- UPDATED MESSAGE PROCESSING ---
  void _processPacket(Socket c, List<int> b) async {
    try {
      // 0. CHECK RATE LIMIT
      if (!RateLimiter.isAllowed(c)) {
        _log("SEC", "RATE LIMIT EXCEEDED: ${c.remoteAddress.address}");
        return; // Drop packet
      }

      final s = utf8.decode(b).trim();
      if (s.isEmpty) return;

      // HANDSHAKE PHASE
      if (!_secureChannels.containsKey(c)) {
        if (s.startsWith("KEY_EXCHANGE|")) {
          try {
            final parts = s.split('|');
            final peerPubKey = base64Decode(parts[1]);
            final ke = _keyExchanges[c]!;
            final sharedSecret = ke.computeSharedSecret(peerPubKey);
            final sessionKey = ke.deriveSessionKey(sharedSecret, "salt", "HawkLink-v1");
            
            setState(() {
              _secureChannels[c] = SecureChannel(sessionKey);
            });
            _log("SEC", "SECURE CHANNEL ESTABLISHED: ${c.remoteAddress.address}");
          } catch(e) {
            _log("SEC", "HANDSHAKE FAILED: $e");
            c.close();
          }
        }
        return;
      }

      // ENCRYPTED TRAFFIC
      final channel = _secureChannels[c]!;
      EncryptedMessage msg;
      try {
        final bytes = base64Decode(s);
        msg = EncryptedMessage.fromBytes(bytes);
      } catch(e) { return; } // Invalid format
      
      final dec = channel.decrypt(msg);
      final j = jsonDecode(dec);

      // PHASE 3: INPUT VALIDATION
      if (!InputValidator.validatePacket(j)) {
        _log("SEC", "DROPPED INVALID PACKET from ${c.remoteAddress.address}");
        return;
      }

      if(j['type']=='STATUS') _updateUnit(c,j);
      else if(j['type']=='CHAT'||j['type']=='ACK') {
        _log(j['sender'],j['content']);
        String content = j['content'].toString().toUpperCase();
        if(content.contains("SOS") || content.contains("BURN BAG") || content.contains("BLACK BOX") || content.contains("BREACH")) {
          _playAlert('alert.mp3');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("⚠️ ALERT: ${j['sender']} - $content", style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ));
        }
      }
      else if(j['type']=='IMAGE') {
        String p=await _saveImageToDisk(j['sender'],j['content']);
        _log(j['sender'], "📸 INTEL RECEIVED", imagePath:p);
        _playSfx('connect.mp3');
      }
      else if (j['type'] == 'INTEL_AUDIO') {
        Map<String, dynamic> meta = {
          'lat': j['lat'], 'lng': j['lng'], 'bpm': j['bpm'],
          'spO2': j['spO2'], 'bp': j['bp'], 'timestamp': j['timestamp']
        };
        String p = await _saveAudioToDisk(j['sender'], j['content'], meta);
        _log(j['sender'], "🎙️ AUDIO LOG REC", audioPath: p, meta: meta);
        _playSfx('connect.mp3');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("🎙️ BLACK BOX AUDIO RECEIVED", style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.blueAccent,
          duration: Duration(seconds: 2),
        ));
      }
      else if(j['type']=='HEAT_STRESS') {
        _log(j['sender'], "⚠️ HEAT STRESS ALERT");
        _playAlert('alert.mp3');
      }
       else if(j['type']=='VOICE') {
         try {
           final audioBytes = base64Decode(j['content']);
           _voiceReceiver.playAudio(audioBytes);
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(
             content: Row(children: [const Icon(Icons.record_voice_over, color: Colors.white), const SizedBox(width:8), Text("${j['sender']} SPEAKING...")],),
             duration: const Duration(milliseconds: 1500),
             backgroundColor: kSciFiDarkBlue
           ));
           _log(j['sender'], "VOICE MESSAGE RECEIVED");

           // RE-BROADCAST TO SQUAD
           for(var u in _units) {
             if (u.id != j['sender'] && u.socket != null) {
               _sendToSocket(u.socket, j);
             }
           }
         } catch(e) {}
      }
      else if(j['type']=='CASEVAC_ALERT') {
        _playAlert('alert.mp3');
        _log(j['sender'], "🚨 CASEVAC REQUESTED (PRIORITY: ${j['priority']})");
        showDialog(context: context, builder: (c) => AlertDialog(
          backgroundColor: Colors.red[900],
          title: const Text("🚨 CASEVAC REQUEST", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Text("UNIT ${j['sender']} REQUESTS IMMEDIATE EVACUATION.\nPRIORITY: ${j['priority']}", style: const TextStyle(color: Colors.white)),
          actions: [TextButton(child: const Text("ACKNOWLEDGE", style: TextStyle(color: Colors.white)), onPressed: ()=>Navigator.pop(c))]
        ));
      }
    } catch(e){
       debugPrint("Processing Error: $e");
    }
  }

  void _sendToSocket(Socket? s, Map<String, dynamic> data) {
    if(s == null || !_secureChannels.containsKey(s)) return;
    try {
      final channel = _secureChannels[s]!;
      final jsonStr = jsonEncode(data);
      final msg = channel.encrypt(jsonStr);
      final b64 = base64Encode(msg.toBytes());
      s.add(utf8.encode("$b64\n"));
    } catch(e) {}
  }

  void _updateUnit(Socket s, Map<String,dynamic> d) {
    setState(() {
      final id=d['id'];
      final idx=_units.indexWhere((u)=>u.id==id);
      final loc=LatLng(d['lat'],d['lng']);
      
      // Extract Triage Data (Safe defaults)
      String tColor = d['triage_color'] ?? "FF4CAF50"; // Green default
      bool casevac = d['casevac'] ?? false;
      
      if(idx!=-1){
        var u = _units[idx];
        u.location=loc;
        u.heading=(d['head']??0.0).toDouble();
        u.role=d['role']??"ASSAULT";
        u.battery=d['bat'];
        u.bpm=d['bpm']??75;
        u.spO2=d['spo2']??98;
        u.bp=d['bp']??"120/80";
        u.temp=(d['temp']??98.6).toDouble();
        u.status=d['state'];
        u.isHeatStress = d['heat']??false;
        u.triageColor = tColor;
        u.isCasevacRequested = casevac;
        u.lastSeen=DateTime.now();
        u.socket=s;
        _checkGeofences(u);
        if(u.pathHistory.isEmpty || const Distance().as(LengthUnit.Meter, u.pathHistory.last, loc)>5) u.pathHistory.add(loc);
      } else {
        var newUnit = SoldierUnit(
          id:id, location:loc, role:d['role']??"ASSAULT", battery:d['bat'], bpm:d['bpm']??75,
          spO2:d['spo2']??98, bp:d['bp']??"120/80", temp:(d['temp']??98.6).toDouble(),
          status:d['state'], isHeatStress: d['heat']??false,
          triageColor: tColor, isCasevacRequested: casevac,
          lastSeen:DateTime.now(), socket:s, history:[loc]
        );
        _checkGeofences(newUnit);
        _units.add(newUnit);
        _log("NET", "UNIT REGISTERED: $id");
        _playSfx('connect.mp3'); 
        _sendToSocket(s, {'type': 'CHAT', 'sender': 'COMMAND', 'content': 'UPLINK ESTABLISHED'});
      }
    });
  }

  // --- UPDATED LOG FUNCTION (Accepts Meta) ---
  void _log(String s, String m, {String? imagePath, String? audioPath, Map<String, dynamic>? meta}) {
    String t=DateFormat('HH:mm:ss').format(DateTime.now());
    setState(()=>_logs.insert(0, {'text':"[$t] $s: $m", 'image':imagePath, 'audio':audioPath, 'meta': meta}));
    if(_logs.length>200) _logs.removeLast();
    // _saveLog("[$t] $s: $m"); // Legacy plaintext save disabled
    SecureLogger.log(s, m); // Encrypted persistence
  }

  void _loadSecureLogs() async {
    final logs = await SecureLogger.readLogs();
    setState(() {
      for(var l in logs) {
        _logs.add({'text': l, 'time': DateTime.now()}); 
      }
    });
  }

  void _handleCommandInput(String input) { if(input.isEmpty) return; if (input.startsWith('@')) { List<String> p = input.split(' '); if (p.isNotEmpty) { String id = p[0].substring(1).toUpperCase().trim(); String c = p.skip(1).join(' '); try { final u = _units.firstWhere((u) => u.id.toUpperCase().trim() == id); if (u.socket != null) { _sendToSocket(u.socket, {'type': 'CHAT', 'sender': 'COMMAND (PVT)', 'content': ">> $c"}); _log("CMD", "TO $id: $c"); _playSfx('order.mp3'); } else { _log("CMD", "ERROR: $id OFFLINE"); } } catch (e) { _log("CMD", "ERROR: UNIT '$id' NOT FOUND"); } } } else { _broadcastOrder(input); } _cmdController.clear(); }
  void _broadcastOrder(String t) { for(var u in _units) _sendToSocket(u.socket, {'type':'CHAT', 'sender':'COMMAND', 'content':t}); _log("CMD", "BROADCAST: $t"); _playSfx('order.mp3'); }
  void _issueMoveOrder(LatLng d) { if(_isDrawingMode||_placingWaypointType!=null||_isDeleteWaypointMode||_selectedUnitId==null||_isMeasureMode) return; try{ final u=_units.firstWhere((x)=>x.id==_selectedUnitId); _sendToSocket(u.socket, {'type':'MOVE_TO', 'sender':'COMMAND', 'content':"MOVE TO ${d.latitude.toStringAsFixed(4)}, ${d.longitude.toStringAsFixed(4)}", 'lat':d.latitude, 'lng':d.longitude}); _log("CMD", "VECTOR ASSIGNED: $u.id"); _playSfx('order.mp3'); }catch(e){} }
  void _showAiAnalysis() {
    AnalysisResult result = FormationAdvisor.analyze(_units);
    
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: Colors.black.withOpacity(0.9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: const BorderSide(color: Colors.purpleAccent, width: 2)),
      title: Row(children: [const Icon(Icons.psychology, color: Colors.purpleAccent), const SizedBox(width: 10), const Text("AI TACTICAL ADVISOR", style: TextStyle(color: Colors.purpleAccent, fontFamily: 'Orbitron'))]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("SQUAD ANALYSIS COMPLETE", style: const TextStyle(color: Colors.grey, fontSize: 10, letterSpacing: 2)),
        const SizedBox(height: 10),
        Text(result.formationName, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, fontFamily: 'Orbitron')),
        Text("CONFIDENCE: ${(result.confidence*100).toInt()}%", style: TextStyle(color: result.confidence > 0.8 ? kSciFiGreen : Colors.orange, fontSize: 12)),
        const SizedBox(height: 15),
        Text(result.description, style: const TextStyle(color: Colors.white70)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.grey))),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent),
          icon: const Icon(Icons.check),
          label: const Text("APPLY FORMATION"),
          onPressed: () {
            Navigator.pop(context);
            _applyFormation(result.formationName);
          },
        )
      ],
    ));
  }
  
  void _applyFormation(String type) {
    // Generate waypoints based on formation type
    // This is a mockup of the actual waypoint generation logic
    // In a real scenario, this would calculate lat/lng depending on the commander's objective or average unit position
    _log("AI", "APPLYING FORMATION PROTOCOL: $type");
    _playSfx('connect.mp3');
  }

  void _deployWaypoint(LatLng l, String type) {
    setState(() {
      _waypoints.add(TacticalWaypoint(id: "WP-${DateTime.now().millisecondsSinceEpoch}", type: type, location: l, created: DateTime.now()));
    });
    _playSfx('connect.mp3');
    _broadcastWaypoints();
  }

  void _removeWaypointNear(LatLng l) {
    setState(() {
      _waypoints.removeWhere((w) {
         final dist = const Distance().as(LengthUnit.Meter, w.location, l);
         return dist < 50; // Delete if within 50m
      });
    });
    _playSfx('disconnect.mp3');
    _broadcastWaypoints();
  }
  
  void _broadcastWaypoints() {
    // Implement broadcast if needed, or just keep local for now
    // For now, assume waypoints are sync'd differently or implementation is omitted
  } 



  void _onMapTap(TapPosition p, LatLng l) { if (_isMeasureMode) { setState(() => _measurePoints.add(l)); _playSfx('connect.mp3'); return; } if(_isDeleteWaypointMode){ _removeWaypointNear(l); setState(()=>_isDeleteWaypointMode=false); return; } if(_placingWaypointType!=null){ _deployWaypoint(l, _placingWaypointType!); setState(()=>_placingWaypointType=null); return; } if(_isDrawingMode){ setState(()=>_tempDrawPoints.add(l)); return; } setState(()=>_selectedUnitId=null); }
  void _toggleMeasureMode() { setState(() { if (_isMeasureMode) { _measurePoints.clear(); _isMeasureMode = false; } else { _isMeasureMode = true; _measurePoints.clear(); _isDrawingMode = false; _placingWaypointType = null; _isDeleteWaypointMode = false; } }); }
  void _clearMeasurements() { setState(() => _measurePoints.clear()); }
  void _toggleDrawingMode() { setState(() { _isDrawingMode=!_isDrawingMode; _tempDrawPoints=[]; }); }
  void _deployCustomZone() { if(_tempDrawPoints.length<3) return; setState(() { _activeDangerZone=List.from(_tempDrawPoints); _isDrawingMode=false; _tempDrawPoints=[]; }); List<List<double>> pts=_activeDangerZone.map((p)=>[p.latitude, p.longitude]).toList(); for(var u in _units) _sendToSocket(u.socket, {'type':'ZONE', 'sender':'COMMAND', 'points':pts}); _log("CMD", "ZONE DEPLOYED"); _playAlert('alert.mp3'); }
  void _clearZone() { setState(() { _activeDangerZone=[]; _tempDrawPoints=[]; }); for(var u in _units) _sendToSocket(u.socket, {'type':'ZONE', 'sender':'COMMAND', 'points':[]}); _log("CMD", "ZONE CLEARED"); }
  IconData _getRoleIcon(String r) { switch(r){ case "MEDIC": return Icons.medical_services; case "SCOUT": return Icons.visibility; case "SNIPER": return Icons.gps_fixed; case "ENGINEER": return Icons.build; default: return Icons.shield; } }
  IconData _getWaypointIcon(String t) { switch(t) { case "RALLY": return Icons.flag; case "ENEMY": return Icons.warning_amber_rounded; case "MED": return Icons.medical_services; case "LZ": return Icons.flight_land; default: return Icons.location_on; } }
  Color _getWaypointColor(String t) { switch(t) { case "RALLY": return Colors.blueAccent; case "ENEMY": return kSciFiRed; case "MED": return Colors.white; case "LZ": return kSciFiGreen; default: return kSciFiCyan; } }
  List<LatLng> _createVisionCone(LatLng c, double h) { double r=0.0005; double a=h*(math.pi/180); double w=45*(math.pi/180); return [c, LatLng(c.latitude+r*math.cos(a-w/2), c.longitude+r*math.sin(a-w/2)), LatLng(c.latitude+r*math.cos(a), c.longitude+r*math.sin(a)), LatLng(c.latitude+r*math.cos(a+w/2), c.longitude+r*math.sin(a+w/2)), c]; }
  void _showImagePreview(String p) { 
    showDialog(context: context, builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent, 
      child: Stack(
        alignment: Alignment.center, 
        children: [
          SecureImageThumbnail(path: p, fit: BoxFit.contain), 
          Positioned(
            top: 10, right: 10, 
            child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 30), onPressed: () => Navigator.pop(ctx))
          )
        ]
      )
    )); 
  }
  String _formatCoord(double v, bool l) { return "${v.abs().toStringAsFixed(5)}° ${l ? (v >= 0 ? "N" : "S") : (v >= 0 ? "E" : "W")}"; }
  void _recenterMap() { if (_units.isEmpty) return; LatLng t; double z = 15.0; if (_selectedUnitId != null) { try { t = _units.firstWhere((u) => u.id == _selectedUnitId).location; z = 17.0; } catch (e) { t = _units.first.location; } } else { double ls = 0; double lns = 0; for (var u in _units) { ls += u.location.latitude; lns += u.location.longitude; } t = LatLng(ls / _units.length, lns / _units.length); } _mapController.move(t, z); _playSfx('connect.mp3'); }
  double _getTotalMeasureDistance() { double t = 0.0; const d = Distance(); for (int i = 0; i < _measurePoints.length - 1; i++) { t += d.as(LengthUnit.Meter, _measurePoints[i], _measurePoints[i+1]); } return t; }

  // --- RESTORED: SIGNAL BARS HELPER ---
  Widget _buildSignalBars(int seconds) {
    int bars = 4;
    Color c = kSciFiGreen;
    if (seconds > kSignalLost) { bars = 0; c = Colors.grey; }
    else if (seconds > kSignalWarning) { bars = 2; c = Colors.orange; }
    return Row(
      children: List.generate(4, (i) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        width: 3, height: 4 + (i*2.0),
        color: i < bars ? c : Colors.white10,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const CrtOverlay(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SciFiPanel(
                width: 350,
                child: Column(
                  children: [
                    const SciFiHeader(label: "HAWKLINK // C2"),
                    // --- QR CODE & IP ---
                    Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("IP: ${_myIps.isNotEmpty ? _myIps.first : '...'}", style: const TextStyle(color: kSciFiGreen, fontSize: 10, fontFamily: 'Courier New')),
                      IconButton(icon: const Icon(Icons.qr_code, color: kSciFiCyan, size: 20), tooltip: "Quick Join QR", padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: _showQuickJoinQR)
                    ])),

                    // --- TERRAIN WIDGET WITH DIRECT UPDATE ---
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(4)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text("TEMP: ${_terrain.temperature.toStringAsFixed(1)}°C", style: const TextStyle(color: kSciFiCyan, fontSize: 10, fontFamily: 'Courier New')),
                            Text("WIND: ${_terrain.windSpeed.toStringAsFixed(0)} km/h ${_terrain.windDirection}", style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'Courier New')),
                          ]),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(_terrain.condition.toUpperCase(), style: TextStyle(color: _terrain.condition == 'Clear' ? kSciFiGreen : Colors.orange, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'Orbitron')),
                            // UPDATED: DIRECT SYNC BUTTON REPLACING SETTINGS
                            GestureDetector(
                                onTap: () {
                                  _fetchWeatherForLocation(_mapController.camera.center);
                                },
                                child: _isWeatherUpdating
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kSciFiGreen))
                                    : const Icon(Icons.refresh, size: 16, color: kSciFiGreen)
                            )
                          ])
                        ],
                      ),
                    ),

                    Expanded(
                      flex: 3,
                      child: ListView.builder(
                        itemCount: _units.length,
                        itemBuilder: (ctx, i) {
                          final u = _units[i];
                          bool isSelected = u.id == _selectedUnitId;
                          bool isCritical = u.status == "SOS" || u.bpm > 140;
                          bool isLost = u.status == "LOST";
                          bool isKilled = u.status == "KILLED";
                          bool isHeat = u.isHeatStress;
                          bool isBreach = u.inDangerZone;
                          Color mainColor = kSciFiGreen;
                          if (isKilled) mainColor = Colors.red; else if (isLost) mainColor = Colors.grey; else if (u.status == "SOS" || isHeat || isBreach) mainColor = kSciFiRed; else if (u.isDeadReckoning) mainColor = Colors.amber;
                          if (isSelected) mainColor = kSciFiCyan;

                          return AnimatedBuilder(
                            animation: _pulseController,
                            builder: (context, child) {
                              Color displayColor = mainColor;
                              if ((u.status == "SOS" || isHeat || isBreach) && !isKilled && !isLost) { displayColor = Color.lerp(mainColor, mainColor.withOpacity(0.3), _pulseController.value)!; }
                              return GestureDetector(
                                onTap: () { setState(() => _selectedUnitId = u.id); _mapController.move(u.location, 17); },
                                child: SciFiPanel(
                                  borderColor: displayColor.withOpacity(0.8),
                                  showBg: true,
                                  child: Opacity(
                                    opacity: isLost ? 0.6 : 1.0,
                                    child: Column(
                                      children: [
                                        Row(children: [
                                          Icon(u.isDeadReckoning ? Icons.saved_search : _getRoleIcon(u.role), color: displayColor, size: 18),
                                          const SizedBox(width: 8),
                                          Text(u.id, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Orbitron', fontSize: 14)),
                                          const Spacer(),
                                          _buildSignalBars(u.secondsSincePing),
                                          const SizedBox(width: 8),
                                          if(u.status=="SOS") BlinkingText("SOS", color: kSciFiRed)
                                          else if(isBreach) BlinkingText("ZONE BREACH", color: kSciFiRed)
                                          else if(isHeat) BlinkingText("HEAT STRESS", color: kSciFiRed)
                                            else if(isKilled) const Text("ZEROIZED", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 10))
                                              else if(isLost) const Text("LOST", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 10))
                                                else if(u.isDeadReckoning) const Text("DR MODE", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 10))
                                                  else Text("ACTIVE", style: TextStyle(color: mainColor, fontSize: 10))
                                        ]),
                                        const SizedBox(height: 8),
                                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text("BPM", style: TextStyle(color: Colors.grey, fontSize: 8)), Row(children: [ Text(isLost ? "--" : "${u.bpm}", style: TextStyle(color: (isCritical || isHeat) ? kSciFiRed : Colors.white, fontSize: 20, fontFamily: 'Orbitron', fontWeight: FontWeight.bold)), const SizedBox(width: 4), Icon(Icons.monitor_heart, size: 12, color: (isCritical || isHeat) ? kSciFiRed : kSciFiGreen) ]), ]),
                                          SizedBox(width: 70, height: 30, child: isLost ? Container(height: 1, color: Colors.grey) : CustomPaint(painter: EkgPainter(animationValue: _ekgController.value, color: (isCritical || isHeat) ? kSciFiRed : kSciFiGreen))),
                                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [ Row(children: [ Text("BP: ", style: TextStyle(color: Colors.grey, fontSize: 8)), Text(isLost ? "--" : u.bp, style: TextStyle(color: (isCritical || isHeat) ? kSciFiRed : Colors.white, fontSize: 11, fontFamily: 'Orbitron', fontWeight: FontWeight.bold)) ]), const SizedBox(height: 2), Text("SpO2 | TEMP", style: TextStyle(color: Colors.grey, fontSize: 8)), Text(isLost ? "--" : "${u.spO2}% | ${u.temp.toStringAsFixed(1)}°F", style: TextStyle(color: kSciFiCyan, fontSize: 11, fontFamily: 'Orbitron', fontWeight: FontWeight.bold)) ]),
                                        ]),
                                        const SizedBox(height: 8),
                                        Row(children: [ Text("BAT", style: TextStyle(color: Colors.grey, fontSize: 8)), const SizedBox(width: 8), Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: u.battery / 100, backgroundColor: Colors.white10, valueColor: AlwaysStoppedAnimation(u.battery < 20 ? kSciFiRed : kSciFiGreen), minHeight: 4))), const SizedBox(width: 8), Text("${u.battery}%", style: TextStyle(color: Colors.grey, fontSize: 8)) ]),
                                        if(isSelected && !isKilled) ...[
                                          const Divider(color: Colors.white10),
                                          Container(margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: Colors.black26, border: Border.all(color: Colors.white10)), child: Column(children: [ Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ Text("LAT: ${_formatCoord(u.location.latitude, true)}", style: const TextStyle(color: kSciFiCyan, fontSize: 10, fontFamily: 'Courier New')), Text("LNG: ${_formatCoord(u.location.longitude, false)}", style: const TextStyle(color: kSciFiCyan, fontSize: 10, fontFamily: 'Courier New')) ]) ])),
                                          if (_waypoints.isNotEmpty) ...[ const SizedBox(height: 4), const Text("WAYPOINT PROXIMITY", style: TextStyle(color: Colors.grey, fontSize: 8, letterSpacing: 1)), ..._waypoints.map((wp) { double dist = const Distance().as(LengthUnit.Meter, u.location, wp.location); return Padding(padding: const EdgeInsets.symmetric(vertical: 2.0), child: Row(children: [ Icon(_getWaypointIcon(wp.type), size: 10, color: _getWaypointColor(wp.type)), const SizedBox(width: 4), Text(wp.type, style: const TextStyle(color: Colors.white70, fontSize: 10)), const Spacer(), Text("${dist.toStringAsFixed(0)}m", style: const TextStyle(color: kSciFiGreen, fontFamily: 'Courier New', fontSize: 10, fontWeight: FontWeight.bold)) ])); }).toList(), const SizedBox(height: 8) ],
                                          SizedBox(width: double.infinity, height: 30, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.red.withOpacity(0.2), foregroundColor: Colors.red), icon: const Icon(Icons.delete_forever, size: 16), label: const Text("ZEROIZE UNIT", style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.bold)), onPressed: () => _sendKillCommand(u)))
                                        ]
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),

                    // --- UPDATED COMMS LOG (With Audio Player) ---
                    Expanded(
                        flex: 2,
                        child: SciFiPanel(
                            title: "COMMS LOG",
                            borderColor: kSciFiCyan,
                            child: ListView.builder(
                                reverse: true,
                                itemCount: _logs.length,
                                padding: EdgeInsets.zero,
                                itemBuilder: (c, i) {
                                  final l=_logs[i];
                                  final meta = l['meta'] as Map<String, dynamic>?;

                                  return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(l['text'], style: const TextStyle(color: kSciFiGreen, fontSize: 9, fontFamily: 'Courier New')),
                                            // Image Preview
                                            if(l['image']!=null)
                                              GestureDetector(
                                                  onTap: ()=>_showImagePreview(l['image']),
                                                  child: Container(
                                                      margin: const EdgeInsets.only(top: 4),
                                                      height: 60, width: 100,
                                                      decoration: BoxDecoration(border: Border.all(color: kSciFiCyan)),
                                                      child: SecureImageThumbnail(path: l['image'], fit: BoxFit.cover)
                                                  )
                                              ),
                                            // Audio Player
                                            if(l['audio']!=null)
                                              Container(
                                                margin: const EdgeInsets.only(top: 4),
                                                width: 220, // Wider for metadata
                                                padding: const EdgeInsets.all(4),
                                                decoration: BoxDecoration(
                                                    color: _currentlyPlayingPath == l['audio'] ? kSciFiCyan.withOpacity(0.2) : Colors.black,
                                                    border: Border.all(color: _currentlyPlayingPath == l['audio'] ? kSciFiCyan : Colors.grey)
                                                ),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        IconButton(
                                                          icon: Icon(_currentlyPlayingPath == l['audio'] ? Icons.stop : Icons.play_arrow, size: 20, color: Colors.white),
                                                          onPressed: () => _playAudioLog(l['audio']),
                                                          padding: EdgeInsets.zero,
                                                          constraints: const BoxConstraints(),
                                                        ),
                                                        const SizedBox(width: 8),
                                                        const Text("AUDIO LOG", style: TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Orbitron')),
                                                        const Spacer(),
                                                        if (_currentlyPlayingPath == l['audio'])
                                                          SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2, color: kSciFiCyan))
                                                      ],
                                                    ),
                                                    // --- METADATA DISPLAY ---
                                                    if (meta != null) ...[
                                                      const Divider(color: Colors.white24, height: 4),
                                                      Text("LOC: ${meta['lat'].toStringAsFixed(4)}, ${meta['lng'].toStringAsFixed(4)}", style: const TextStyle(color: Colors.grey, fontSize: 9)),
                                                      Row(
                                                        children: [
                                                          Icon(Icons.monitor_heart, size: 10, color: kSciFiRed),
                                                          Text(" ${meta['bpm']} | BP: ${meta['bp']} | O2: ${meta['spO2']}%", style: const TextStyle(color: kSciFiGreen, fontSize: 9, fontWeight: FontWeight.bold)),
                                                        ],
                                                      )
                                                    ]
                                                  ],
                                                ),
                                              )
                                          ]
                                      )
                                  );
                                }
                            )
                        )
                    ),
                    Padding(padding: const EdgeInsets.all(8.0), child: TextField(controller: _cmdController, style: const TextStyle(color: kSciFiCyan, fontFamily: 'Courier New'), decoration: const InputDecoration(hintText: "CMD: @UNIT [MSG] or [BROADCAST]", hintStyle: TextStyle(color: Colors.grey, fontSize: 12), filled: true, fillColor: kSciFiDarkBlue, border: OutlineInputBorder(borderSide: BorderSide(color: kSciFiCyan)), isDense: true), onSubmitted: _handleCommandInput)),
                  ],
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Transform(
                      transform: Matrix4.identity()..setEntry(3, 2, 0.001)..rotateX(-_tilt),
                      alignment: Alignment.center,
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(initialCenter: const LatLng(17.3850, 78.4867), initialZoom: 14, initialRotation: _rotation, onTap: _onMapTap, onLongPress: (tapPos, point) => _issueMoveOrder(point)),
                        children: [
                          TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: 'com.hawklink.commander'),
                          if (_activeDangerZone.isNotEmpty) PolygonLayer(polygons: [Polygon(points: _activeDangerZone, color: kSciFiRed.withOpacity(0.2), borderColor: kSciFiRed, borderStrokeWidth: 2, isFilled: true)]),
                          if (_isDrawingMode && _tempDrawPoints.isNotEmpty) ...[PolylineLayer(polylines: [Polyline(points: _tempDrawPoints, color: Colors.orange, strokeWidth: 2, isDotted: true)]), MarkerLayer(markers: _tempDrawPoints.map((p) => Marker(point: p, width: 10, height: 10, child: Container(decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle)))).toList())],
                          if (_showGrid) IgnorePointer(child: CustomPaint(size: Size.infinite, painter: TacticalGridPainter())),
                          if (_showTrails) PolylineLayer(polylines: _units.map((u) => Polyline(points: u.pathHistory, strokeWidth: 2.0, color: u.status=="SOS" ? kSciFiRed : kSciFiGreen, isDotted: true)).toList()),
                          PolygonLayer(polygons: _units.map((u) => Polygon(points: _createVisionCone(u.location, u.heading), color: kSciFiCyan.withOpacity(0.15), isFilled: true, borderStrokeWidth: 0)).toList()),
                          if (_selectedUnitId != null && _showRangeRings) CircleLayer(circles: [CircleMarker(point: _units.firstWhere((u) => u.id == _selectedUnitId).location, radius: 50, color: Colors.transparent, borderColor: kSciFiCyan.withOpacity(0.5), borderStrokeWidth: 1, useRadiusInMeter: true)]),
                          if (_measurePoints.isNotEmpty) ...[ MarkerLayer(markers: _measurePoints.map((p) => Marker(point: p, width: 20, height: 20, child: Icon(Icons.circle, size: 10, color: Colors.purpleAccent))).toList()), if (_measurePoints.length > 1) PolylineLayer(polylines: [Polyline(points: _measurePoints, color: Colors.purpleAccent, strokeWidth: 2.0, isDotted: true)]), if (_measurePoints.length > 1) MarkerLayer(markers: [Marker(point: _measurePoints.last, width: 80, height: 60, alignment: Alignment.bottomCenter, child: Container(margin: const EdgeInsets.only(top: 20), padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1), decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), borderRadius: BorderRadius.circular(2), border: Border.all(color: Colors.purpleAccent, width: 0.5)), child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [Text("DIST: ${_getTotalMeasureDistance().toStringAsFixed(0)}m", style: const TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 8)), const Text("(TAP)", style: TextStyle(color: Colors.white54, fontSize: 6))])))]), ],
                          if (_selectedUnitId != null && _waypoints.isNotEmpty) ...[ PolylineLayer(polylines: _waypoints.map((wp) { try { final unit = _units.firstWhere((u) => u.id == _selectedUnitId); return Polyline(points: [unit.location, wp.location], strokeWidth: 1.0, color: kSciFiCyan.withOpacity(0.5), isDotted: true); } catch (e) { return Polyline(points: []); } }).toList()), MarkerLayer(markers: _waypoints.map((wp) { try { final unit = _units.firstWhere((u) => u.id == _selectedUnitId); final dist = const Distance().as(LengthUnit.Meter, unit.location, wp.location); final midPoint = LatLng((unit.location.latitude + wp.location.latitude) / 2, (unit.location.longitude + wp.location.longitude) / 2); return Marker(point: midPoint, width: 80, height: 30, child: Container(alignment: Alignment.center, decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(4), border: Border.all(color: kSciFiCyan.withOpacity(0.5))), child: Text("${dist.toStringAsFixed(0)}m", style: const TextStyle(color: kSciFiCyan, fontSize: 10, fontWeight: FontWeight.bold)))); } catch (e) { return Marker(point: const LatLng(0,0), child: const SizedBox()); } }).toList()) ],
                          MarkerLayer(markers: _waypoints.map((wp) => Marker(point: wp.location, width: 50, height: 50, child: Column(children: [Icon(_getWaypointIcon(wp.type), color: _getWaypointColor(wp.type), size: 30), Container(padding: const EdgeInsets.symmetric(horizontal: 4), color: Colors.black54, child: Text(wp.type, style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold)))]) )).toList()),
                          MarkerLayer(markers: _units.map((u) { bool isSelected = u.id == _selectedUnitId; bool isLost = u.status == "LOST"; bool isDr = u.isDeadReckoning; bool isHeat = u.isHeatStress; bool isBreach = u.inDangerZone; Color iconColor = kSciFiCyan; if (isLost) iconColor = Colors.grey; else if (u.status == "SOS" || isHeat || isBreach) iconColor = kSciFiRed; else if (isDr) iconColor = Colors.amber; return Marker(point: u.location, width: 80, height: 80, child: Transform.rotate(angle: -_rotation * (math.pi / 180), child: Stack(alignment: Alignment.center, children: [ if(u.status=="SOS" || isHeat || isBreach) ScaleTransition(scale: _pulseController, child: Container(width: 60, height: 60, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kSciFiRed, width: 2)))), if(isSelected) RotationTransition(turns: _pulseController, child: Container(width: 50, height: 50, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kSciFiCyan, width: 2, style: BorderStyle.solid)))), Column(mainAxisSize: MainAxisSize.min, children: [ Text(u.id, style: TextStyle(color: isSelected ? kSciFiCyan : Colors.white, fontSize: 8, fontWeight: FontWeight.bold, backgroundColor: Colors.black54)), Transform.rotate(angle: (u.heading * (math.pi / 180)), child: Icon(isDr ? Icons.saved_search : _getRoleIcon(u.role), color: iconColor, size: 24)) ]) ]))); }).toList()),
                        ],
                      ),
                    ),
                    if (_showTacticalMatrix) Positioned.fill(child: Container(color: Colors.black.withOpacity(0.85), child: Center(child: SciFiPanel(width: 700, height: 500, title: "TACTICAL DISTANCE MATRIX", borderColor: kSciFiCyan, showBg: true, child: Column(children: [ Padding(padding: const EdgeInsets.all(8.0), child: const Text("UNIT TO OBJECTIVE DISTANCES", style: TextStyle(color: kSciFiGreen, letterSpacing: 2, fontSize: 10))), Expanded(child: _waypoints.isEmpty ? const Center(child: Text("NO ACTIVE WAYPOINTS", style: TextStyle(color: Colors.grey))) : SingleChildScrollView(scrollDirection: Axis.vertical, child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(headingRowColor: MaterialStateProperty.all(kSciFiDarkBlue), dataRowColor: MaterialStateProperty.all(Colors.transparent), columns: [ const DataColumn(label: Text("UNIT", style: TextStyle(color: kSciFiCyan, fontWeight: FontWeight.bold))), ..._waypoints.map((wp) => DataColumn(label: Column(mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(_getWaypointIcon(wp.type), color: _getWaypointColor(wp.type), size: 14), Text(wp.type, style: const TextStyle(color: Colors.white, fontSize: 10)) ]))) ], rows: _units.map((u) { return DataRow(cells: [ DataCell(Text(u.id, style: const TextStyle(color: kSciFiCyan, fontWeight: FontWeight.bold))), ..._waypoints.map((wp) { double dist = const Distance().as(LengthUnit.Meter, u.location, wp.location); Color c = Colors.white; if (dist < 50) c = kSciFiGreen; return DataCell(Text("${dist.toStringAsFixed(0)}m", style: TextStyle(color: c, fontFamily: 'Courier New'))); }) ]); }).toList())))), Padding(padding: const EdgeInsets.all(8.0), child: SciFiButton(label: "CLOSE ANALYSIS", icon: Icons.close, color: kSciFiRed, onTap: () => setState(() => _showTacticalMatrix = false))) ]))))),
                    
                    if (_showCasualtyBoard) Positioned.fill(child: Container(color: Colors.black.withOpacity(0.9), child: Center(child: SciFiPanel(width: 600, height: 600, title: "CASUALTY BOARD // EVAC PRIORITY", borderColor: kSciFiRed, showBg: true, child: Column(children: [
                        Container(padding: const EdgeInsets.all(12), color: Colors.red.withOpacity(0.1), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("UNIT ID", style: TextStyle(color: Colors.grey, fontSize: 10)), const Text("TRIAGE STATUS", style: TextStyle(color: Colors.grey, fontSize: 10)), const Text("VITALS (HR/SpO2/BP)", style: TextStyle(color: Colors.grey, fontSize: 10)), const Text("CASEVAC", style: TextStyle(color: Colors.grey, fontSize: 10))])),
                        Expanded(child: ListView.builder(
                          itemCount: _units.length,
                          itemBuilder: (context, index) {
                             // Sort units: CASEVAC/Red first
                             List<SoldierUnit> sorted = List.from(_units);
                             sorted.sort((a,b) {
                               int scoreA = (a.isCasevacRequested?10:0) + (a.triageColor=="FFFF0000"?5:0);
                               int scoreB = (b.isCasevacRequested?10:0) + (b.triageColor=="FFFF0000"?5:0);
                               return scoreB.compareTo(scoreA);
                             });
                             final u = sorted[index];
                             Color tColor = Color(int.parse(u.triageColor, radix: 16));
                             
                             return Container(
                               margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                               padding: const EdgeInsets.all(8),
                               decoration: BoxDecoration(border: Border.all(color: tColor.withOpacity(0.5))),
                               child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                  Text(u.id, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Orbitron')),
                                  Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:2), decoration: BoxDecoration(color: tColor, borderRadius: BorderRadius.circular(4)), child: Text(tColor==Colors.red?"IMMEDIATE":tColor==Colors.orange?"DELAYED":tColor==Colors.black?"EXPECTANT":"MINIMAL", style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))),
                                  Text("${u.bpm} bpm / ${u.spO2}% / ${u.bp}", style: TextStyle(color: u.bpm<40||u.bpm>120?kSciFiRed:kSciFiGreen, fontFamily: 'Courier New')),
                                  if(u.isCasevacRequested) BlinkingText("REQ EVAC", color: kSciFiRed) else const Text("-", style: TextStyle(color: Colors.grey))
                               ])
                             );
                          }
                        )),
                        Padding(padding: const EdgeInsets.all(8.0), child: SciFiButton(label: "CLOSE BOARD", icon: Icons.close, color: kSciFiCyan, onTap: () => setState(() => _showCasualtyBoard = false)))
                    ]))))),
                    
                    Positioned(top: 20, right: 20, child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height - 150, maxWidth: 100), child: SciFiPanel(showBg: true, width: 100, child: SingleChildScrollView(child: Column(children: [ const SizedBox(height: 10), if (_isDrawingMode) ...[SciFiButton(label: "OK", icon: Icons.check, color: kSciFiGreen, onTap: _deployCustomZone), const SizedBox(height: 8), SciFiButton(label: "X", icon: Icons.close, color: kSciFiRed, onTap: _toggleDrawingMode)] else ...[SciFiButton(label: "Z", icon: _activeDangerZone.isNotEmpty ? Icons.delete : Icons.edit_road, color: kSciFiRed, onTap: _activeDangerZone.isNotEmpty ? _clearZone : _toggleDrawingMode)], const Divider(color: Colors.white24, indent: 10, endIndent: 10), SciFiButton(label: "G", icon: Icons.grid_4x4, color: _showGrid ? kSciFiGreen : Colors.grey, onTap: () => setState(() => _showGrid = !_showGrid)), const SizedBox(height: 8), SciFiButton(label: "R", icon: Icons.radar, color: _showRangeRings ? kSciFiCyan : Colors.grey, onTap: () => setState(() => _showRangeRings = !_showRangeRings)), const SizedBox(height: 8), SciFiButton(label: "T", icon: Icons.timeline, color: _showTrails ? kSciFiCyan : Colors.grey, onTap: () => setState(() => _showTrails = !_showTrails)), const SizedBox(height: 8), SciFiButton(label: "A", icon: Icons.straighten, color: _showTacticalMatrix ? kSciFiGreen : Colors.grey, onTap: () => setState(() => _showTacticalMatrix = !_showTacticalMatrix)), const SizedBox(height: 8), SciFiButton(label: "CAS", icon: Icons.local_hospital, color: _showCasualtyBoard ? kSciFiRed : Colors.grey, onTap: () => setState(() => _showCasualtyBoard = !_showCasualtyBoard)), const Divider(color: Colors.white24, indent: 10, endIndent: 10), SciFiButton(label: "AI", icon: Icons.psychology, color: Colors.purpleAccent, onTap: _showAiAnalysis), const SizedBox(height: 8), if (_measurePoints.isNotEmpty && _isMeasureMode) SciFiButton(label: "CLR", icon: Icons.clear_all, color: Colors.red, onTap: _clearMeasurements) else SciFiButton(label: "M", icon: Icons.square_foot, color: _isMeasureMode ? Colors.purpleAccent : Colors.grey, onTap: _toggleMeasureMode), const SizedBox(height: 8), SciFiButton(label: "3D", icon: Icons.threed_rotation, color: _tilt > 0 ? kSciFiGreen : Colors.grey, onTap: () => setState(() => _tilt = _tilt > 0 ? 0.0 : 0.6)), const SizedBox(height: 8), SciFiButton(label: "<", icon: Icons.rotate_left, color: Colors.white, onTap: () { setState(() => _rotation -= 45); _mapController.rotate(_rotation); }), const SizedBox(height: 8), SciFiButton(label: ">", icon: Icons.rotate_right, color: Colors.white, onTap: () { setState(() => _rotation += 45); _mapController.rotate(_rotation); }), const SizedBox(height: 10) ]))))),
                    if (_isMeasureMode) Positioned(top: 20, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.purpleAccent)), child: Text(_measurePoints.isEmpty ? "TAP START POINT" : "TAP TO ADD POINT", style: const TextStyle(color: Colors.purpleAccent, fontFamily: 'Orbitron', fontWeight: FontWeight.bold))))),
                    if (!_isDrawingMode) Positioned(bottom: 100, right: 20, child: SciFiPanel(showBg: true, borderColor: kSciFiCyan, child: IconButton(icon: const Icon(Icons.center_focus_strong, color: kSciFiCyan), onPressed: _recenterMap, tooltip: "RECENTER"))),
                    if (!_isDrawingMode) Positioned(bottom: 30, left: 20, right: 20, child: Center(child: SciFiPanel(showBg: true, borderColor: kSciFiGreen.withOpacity(0.5), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8.0), child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [SciFiButton(label: "RALLY", icon: Icons.flag, color: Colors.blue, onTap: () => setState(() => _placingWaypointType = "RALLY")), const SizedBox(width: 8), SciFiButton(label: "ENEMY", icon: Icons.warning, color: kSciFiRed, onTap: () => setState(() => _placingWaypointType = "ENEMY")), const SizedBox(width: 8), SciFiButton(label: "MED", icon: Icons.medical_services, color: Colors.white, onTap: () => setState(() => _placingWaypointType = "MED")), const SizedBox(width: 8), SciFiButton(label: "LZ", icon: Icons.flight_land, color: kSciFiGreen, onTap: () => setState(() => _placingWaypointType = "LZ")), const SizedBox(width: 20), SciFiButton(label: "DEL", icon: Icons.delete, color: _isDeleteWaypointMode ? Colors.red : Colors.orange, onTap: () => setState(() => _isDeleteWaypointMode = !_isDeleteWaypointMode))])))))),
                    if (_isDeleteWaypointMode) Positioned(top: 80, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.red)), child: const Text("TAP WAYPOINT TO DELETE", style: TextStyle(color: Colors.red, fontFamily: 'Orbitron', fontWeight: FontWeight.bold))))),
                    if (_isDrawingMode) Positioned(top: 20, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.orange)), child: const Text("DRAWING MODE: TAP POINTS", style: TextStyle(color: Colors.orange, fontFamily: 'Orbitron'))))),
                    if (_placingWaypointType != null) Positioned(top: 80, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.yellow)), child: Text("PLACE $_placingWaypointType", style: const TextStyle(color: Colors.yellow, fontFamily: 'Orbitron'))))),
                  ],
                ),
              ),
            ],
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
      double y = mid + math.sin(offset * math.pi * 10) * (height / 3);
      if ((offset * 5) % 1 > 0.9) { y -= height / 2; }
      if (x == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }
  @override bool shouldRepaint(covariant EkgPainter oldDelegate) => true;
}