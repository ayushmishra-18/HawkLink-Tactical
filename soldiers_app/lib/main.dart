import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:flutter_tts/flutter_tts.dart';

// --- CONFIGURATION ---
const int kPort = 4444;
const String kPreSharedKey = 'HAWKLINK_TACTICAL_SECURE_KEY_256';
const String kFixedIV =      'HAWKLINK_IV_16ch';

void main() {
  runApp(const SoldierApp());
}

class SoldierApp extends StatelessWidget {
  const SoldierApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF050505),
        colorScheme: const ColorScheme.dark(primary: Colors.greenAccent),
        // FIXED: dialogTheme removed completely to solve the build error.
      ),
      home: const UplinkScreen(),
    );
  }
}

class UplinkScreen extends StatefulWidget {
  const UplinkScreen({super.key});

  @override
  State<UplinkScreen> createState() => _UplinkScreenState();
}

class _UplinkScreenState extends State<UplinkScreen> with SingleTickerProviderStateMixin {
  // NETWORKING
  Socket? _socket;
  String _status = "DISCONNECTED";
  final TextEditingController _ipController = TextEditingController(text: "192.168.1.X");
  final TextEditingController _idController = TextEditingController(text: "ALPHA-1");

  // MESSAGES
  List<Map<String, dynamic>> _messages = [];
  bool _hasUnread = false;

  // SENSORS & MAP
  final MapController _mapController = MapController();
  LatLng _myLocation = const LatLng(40.7128, -74.0060);
  List<Marker> _targetMarkers = [];
  bool _hasFix = false;
  Timer? _heartbeatTimer;
  final Battery _battery = Battery();

  // AUDIO
  final FlutterTts _tts = FlutterTts();

  // ENCRYPTION
  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));

  // ANIMATION
  late AnimationController _sosController;

  @override
  void initState() {
    super.initState();
    _sosController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _startGpsTracking();
    _initTts();
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
    _sosController.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _startGpsTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5)
    ).listen((Position position) {
      if (mounted) {
        setState(() {
          _myLocation = LatLng(position.latitude, position.longitude);
          _hasFix = true;
        });
        if (_hasFix && _mapController.camera.zoom < 5) _mapController.move(_myLocation, 17);
      }
    });
  }

  // --- NETWORKING ---
  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() => _status = "SEARCHING...");
    try {
      _socket = await Socket.connect(_ipController.text, kPort, timeout: const Duration(seconds: 5));
      setState(() => _status = "SECURE UPLINK ESTABLISHED");
      _tts.speak("Secure Uplink Established");

      _socket!.listen(
            (data) => _handleIncomingPacket(data),
        onDone: () {
          if (mounted) setState(() { _status = "CONNECTION LOST"; _socket = null; });
          _tts.speak("Connection Lost");
        },
        onError: (e) {
          if (mounted) setState(() { _status = "ERROR: $e"; _socket = null; });
        },
      );

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (timer) => _sendHeartbeat());
    } catch (e) {
      if (mounted) setState(() { _status = "FAILED TO CONNECT"; _socket = null; });
    }
  }

  void _disconnect() {
    _socket?.destroy();
    if (mounted) setState(() { _status = "DISCONNECTED"; _socket = null; });
  }

  void _handleIncomingPacket(List<int> data) {
    try {
      final str = utf8.decode(data).trim();
      if (str.isEmpty) return;
      final decrypted = _encrypter.decrypt64(str, iv: _iv);
      final json = jsonDecode(decrypted);
      if (json['type'] == 'CHAT' || json['type'] == 'MOVE_TO') _onMessageReceived(json);
    } catch (e) { debugPrint("Decrypt fail"); }
  }

  void _onMessageReceived(Map<String, dynamic> msg) {
    setState(() {
      _messages.insert(0, {
        'time': DateTime.now(),
        'sender': msg['sender'] ?? 'CMD',
        'content': msg['content'] ?? 'DATA',
        'type': msg['type']
      });
      _hasUnread = true;
    });

    String content = msg['content'] ?? "";
    if (content.isNotEmpty) {
      _tts.speak("New Order: $content");
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: Colors.transparent, elevation: 0,
      content: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.greenAccent.withOpacity(0.9), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text("INCOMING // ${msg['sender']}", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 10)),
          Text(msg['content'] ?? "", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
      ),
    ));
  }

  void _sendHeartbeat() async {
    if (_socket == null) return;
    try {
      int bat = await _battery.batteryLevel;
      String state = _sosController.isAnimating ? "SOS" : "ACTIVE";
      _sendPacket({
        'type': 'STATUS',
        'id': _idController.text.toUpperCase(),
        'lat': _myLocation.latitude, 'lng': _myLocation.longitude,
        'bat': bat, 'state': state
      });
    } catch (e) { /* ignore */ }
  }

  void _sendPacket(Map<String, dynamic> data) {
    if (_socket == null) return;
    try {
      final jsonStr = jsonEncode(data);
      _socket!.write(_encrypter.encrypt(jsonStr, iv: _iv).base64);
    } catch (e) { /* ignore */ }
  }

  // --- ACTIONS ---
  void _markTarget() {
    if (!_hasFix) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("WAITING FOR GPS...")));
      return;
    }
    setState(() => _targetMarkers.add(Marker(point: _myLocation, width: 30, height: 30, child: const Icon(Icons.gps_fixed, color: Colors.redAccent))));
    _sendPacket({
      'type': 'CHAT', 'sender': _idController.text.toUpperCase(),
      'content': 'TARGET DESIGNATED AT ${_myLocation.latitude.toStringAsFixed(5)}, ${_myLocation.longitude.toStringAsFixed(5)}'
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.red, content: Text("TARGET SENT", style: TextStyle(color: Colors.white))));
  }

  void _activateSOS() {
    if (_sosController.isAnimating) {
      _sosController.reset();
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'SOS CANCELLED'});
      _tts.speak("SOS Cancelled");
    } else {
      _sosController.repeat(reverse: true);
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! SOS ACTIVATED !!!'});
      _tts.speak("Emergency Beacon Activated");
      _sendHeartbeat();
    }
    setState(() {});
  }

  void _sendSitrep() {
    TextEditingController ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      // FIXED: Applied styling here locally to avoid global theme errors
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text("SEND SITREP", style: TextStyle(color: Colors.greenAccent)),
      content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
              hintText: "Status report...",
              hintStyle: TextStyle(color: Colors.grey)
          )
      ),
      actions: [
        TextButton(child: const Text("TX", style: TextStyle(color: Colors.greenAccent)), onPressed: () {
          if (ctrl.text.isNotEmpty) {
            _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '[SITREP] ${ctrl.text}'});
            Navigator.pop(ctx);
          }
        })
      ],
    ));
  }

  void _showLogs() {
    setState(() => _hasUnread = false);
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF111111), builder: (ctx) => Container(
      padding: const EdgeInsets.all(16),
      child: ListView.builder(itemCount: _messages.length, itemBuilder: (c, i) => ListTile(
        title: Text(_messages[i]['sender'], style: const TextStyle(color: Colors.grey, fontSize: 10)),
        subtitle: Text(_messages[i]['content'], style: const TextStyle(color: Colors.white)),
        trailing: Text(DateFormat('HH:mm').format(_messages[i]['time']), style: const TextStyle(color: Colors.grey, fontSize: 10)),
      )),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bool isSOS = _sosController.isAnimating;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: _hasFix ? _myLocation : const LatLng(40.7128, -74.0060), initialZoom: 15),
            children: [
              TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: 'com.hawklink.soldier'),
              MarkerLayer(markers: [if (_hasFix) Marker(point: _myLocation, width: 40, height: 40, child: const Icon(Icons.navigation, color: Colors.blueAccent)), ..._targetMarkers]),
            ],
          ),
          if (isSOS) AnimatedBuilder(animation: _sosController, builder: (ctx, ch) => Container(color: Colors.red.withOpacity(0.3 * _sosController.value))),
          SafeArea(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(12), margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), border: Border.all(color: isSOS ? Colors.red : Colors.greenAccent), borderRadius: BorderRadius.circular(8)),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("UPLINK: $_status", style: TextStyle(color: _socket != null ? Colors.greenAccent : Colors.red, fontWeight: FontWeight.bold, fontSize: 10)),
                    ]),
                    if (_socket == null) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [
                      Expanded(flex: 1, child: TextField(controller: _idController, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), decoration: const InputDecoration(labelText: "CALLSIGN"))),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: TextField(controller: _ipController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "COMMAND IP"))),
                      IconButton(icon: const Icon(Icons.link), color: Colors.greenAccent, onPressed: _connect)
                    ]))
                    else Padding(padding: const EdgeInsets.only(top: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("CALLSIGN: ${_idController.text.toUpperCase()}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      IconButton(icon: const Icon(Icons.link_off, color: Colors.red), onPressed: _disconnect)
                    ]))
                  ]),
                ),
                if (_hasUnread) GestureDetector(onTap: _showLogs, child: Container(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), decoration: BoxDecoration(color: Colors.greenAccent, borderRadius: BorderRadius.circular(30)), child: const Text("NEW ORDER", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)))),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.black.withOpacity(0.95),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: _Btn("SITREP", Icons.assignment, Colors.blue, _sendSitrep)),
                      const SizedBox(width: 8),
                      Expanded(child: _Btn("LOGS", _hasUnread ? Icons.mail : Icons.history, _hasUnread ? Colors.green : Colors.white, _showLogs)),
                      const SizedBox(width: 8),
                      Expanded(child: _Btn("MARK", Icons.gps_fixed, Colors.red, _markTarget)),
                    ]),
                    const SizedBox(height: 10),
                    GestureDetector(onLongPress: _activateSOS, child: Container(height: 50, decoration: BoxDecoration(color: isSOS ? Colors.red : const Color(0xFF330000), border: Border.all(color: Colors.red)), child: Center(child: Text(isSOS ? "SOS ACTIVE" : "HOLD SOS", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))))
                  ]),
                ),
              ],
            ),
          ),
          Positioned(top: 180, right: 16, child: FloatingActionButton(mini: true, backgroundColor: Colors.black, child: const Icon(Icons.my_location, color: Colors.greenAccent), onPressed: () { if (_hasFix) _mapController.move(_myLocation, 17); })),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final String l; final IconData i; final Color c; final VoidCallback t;
  const _Btn(this.l, this.i, this.c, this.t);
  @override Widget build(BuildContext context) => Material(color: Colors.grey[900], child: InkWell(onTap: t, child: Container(padding: const EdgeInsets.symmetric(vertical: 16), decoration: BoxDecoration(border: Border.all(color: c.withOpacity(0.5))), child: Column(children: [Icon(i, color: c), Text(l, style: TextStyle(color: c, fontSize: 10))]))));
}