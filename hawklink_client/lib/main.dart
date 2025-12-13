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
import 'package:flutter_compass/flutter_compass.dart';

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

  void _toggleStealth() {
    setState(() => _isStealthMode = !_isStealthMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _isStealthMode ? Colors.black : const Color(0xFF050505),
        colorScheme: ColorScheme.dark(
          primary: _isStealthMode ? Colors.red[900]! : Colors.greenAccent,
          surface: _isStealthMode ? Colors.black : const Color(0xFF1E1E1E),
        ),
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
  final TextEditingController _ipController = TextEditingController(text: "192.168.1.X");
  final TextEditingController _idController = TextEditingController(text: "ALPHA-1");

  // ROLE SELECTION
  String _selectedRole = "ASSAULT";
  final List<String> _roles = ["ASSAULT", "MEDIC", "SCOUT", "SNIPER", "ENGINEER"];

  List<Map<String, dynamic>> _messages = [];
  bool _hasUnread = false;
  List<LatLng> _dangerZone = [];
  bool _isInDanger = false;
  Map<String, dynamic>? _pendingOrder;

  // SENSORS
  final MapController _mapController = MapController();
  LatLng _myLocation = const LatLng(40.7128, -74.0060);
  double _heading = 0.0;
  List<Marker> _targetMarkers = [];
  bool _hasFix = false;
  Timer? _heartbeatTimer;
  final Battery _battery = Battery();
  int _heartRate = 75;
  Timer? _biometricTimer;

  final FlutterTts _tts = FlutterTts();
  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));
  late AnimationController _sosController;

  @override
  void initState() {
    super.initState();
    _sosController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _startGpsTracking();
    _startCompass();
    _initTts();

    _biometricTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) setState(() {
        int base = _sosController.isAnimating ? 110 : 70;
        _heartRate = base + Random().nextInt(15);
      });
    });
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
    Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5)).listen((Position position) {
      if (mounted) {
        setState(() {
          _myLocation = LatLng(position.latitude, position.longitude);
          _hasFix = true;
        });

        if (_dangerZone.isNotEmpty) {
          bool currentlyInDanger = _isPointInside(_myLocation, _dangerZone);
          if (currentlyInDanger && !_isInDanger && !widget.isStealth) {
            _tts.speak("WARNING! Restricted Zone!");
          }
          _isInDanger = currentlyInDanger;
        }
        if (_hasFix && _mapController.camera.zoom < 5) _mapController.move(_myLocation, 17);
      }
    });
  }

  void _startCompass() {
    FlutterCompass.events?.listen((CompassEvent event) {
      if (mounted) {
        setState(() {
          _heading = event.heading ?? 0.0;
        });
      }
    });
  }

  bool _isPointInside(LatLng point, List<LatLng> polygon) {
    int intersectCount = 0;
    for (int j = 0; j < polygon.length - 1; j++) {
      if (_rayCastIntersect(point, polygon[j], polygon[j + 1])) intersectCount++;
    }
    return (intersectCount % 2) == 1;
  }

  bool _rayCastIntersect(LatLng point, LatLng vertA, LatLng vertB) {
    double aY = vertA.latitude; double bY = vertB.latitude;
    double aX = vertA.longitude; double bX = vertB.longitude;
    double pY = point.latitude; double pX = point.longitude;
    if ((aY > pY && bY > pY) || (aY < pY && bY < pY) || (aX < pX && bX < pX)) return false;
    double m = (aY - bY) / (aX - bX);
    double bee = (-aX) * m + aY;
    double x = (pY - bee) / m;
    return x > pX;
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() => _status = "SEARCHING...");
    try {
      _socket = await Socket.connect(_ipController.text, kPort, timeout: const Duration(seconds: 5));
      setState(() => _status = "SECURE UPLINK ESTABLISHED");
      if (!widget.isStealth) _tts.speak("Connected");

      _socket!.listen(
            (data) => _handleIncomingPacket(data),
        onDone: () {
          if (mounted) setState(() { _status = "CONNECTION LOST"; _socket = null; });
          if (!widget.isStealth) _tts.speak("Connection Lost");
        },
        onError: (e) {
          if (mounted) setState(() { _status = "ERROR: $e"; _socket = null; });
        },
      );

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) => _sendHeartbeat());
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

      if (json['type'] == 'ZONE') {
        List<dynamic> points = json['points'];
        setState(() => _dangerZone = points.map((p) => LatLng(p[0], p[1])).toList());
        if (!widget.isStealth) _tts.speak("Zone Updated");
      }
      else if (json['type'] == 'CHAT' || json['type'] == 'MOVE_TO') {
        _onMessageReceived(json);
      }
    } catch (e) { }
  }

  void _onMessageReceived(Map<String, dynamic> msg) {
    setState(() {
      _messages.insert(0, {'time': DateTime.now(), 'sender': msg['sender'], 'content': msg['content'], 'type': msg['type']});
      _hasUnread = true;
      _pendingOrder = msg;
    });
    if (!widget.isStealth) _tts.speak(msg['content']);
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
        'lat': _myLocation.latitude, 'lng': _myLocation.longitude,
        'head': _heading,
        'bat': bat, 'state': state, 'bpm': _heartRate,
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

  void _markTarget() {
    if (!_hasFix) return;
    setState(() => _targetMarkers.add(Marker(point: _myLocation, width: 30, height: 30, child: const Icon(Icons.gps_fixed, color: Colors.redAccent))));
    _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'TARGET DESIGNATED'});
  }

  void _activateSOS() {
    if (_sosController.isAnimating) {
      _sosController.reset();
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'SOS CANCELLED'});
    } else {
      _sosController.repeat(reverse: true);
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! SOS ACTIVATED !!!'});
      if(!widget.isStealth) _tts.speak("Beacon Active");
      _sendHeartbeat();
    }
    setState(() {});
  }

  void _sendSitrep() {
    TextEditingController ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Text("SEND SITREP", style: TextStyle(color: widget.isStealth ? Colors.red : Colors.greenAccent)),
      content: TextField(controller: ctrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: "Report...", hintStyle: TextStyle(color: Colors.grey))),
      actions: [TextButton(child: const Text("TX", style: TextStyle(color: Colors.white)), onPressed: () {
        if (ctrl.text.isNotEmpty) {
          _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '[SITREP] ${ctrl.text}'});
          Navigator.pop(ctx);
        }
      })],
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

  void _acknowledgeOrder() {
    if (_pendingOrder == null) return;
    _sendPacket({'type': 'ACK', 'sender': _idController.text.toUpperCase(), 'content': 'ORDER COPIED'});
    setState(() => _pendingOrder = null);
  }

  @override
  Widget build(BuildContext context) {
    final bool isSOS = _sosController.isAnimating;
    final Color primaryColor = widget.isStealth ? Colors.red[900]! : Colors.greenAccent;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          ColorFiltered(
            colorFilter: widget.isStealth ? const ColorFilter.mode(Colors.black, BlendMode.saturation) : const ColorFilter.mode(Colors.transparent, BlendMode.multiply),
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: _hasFix ? _myLocation : const LatLng(40.7128, -74.0060), initialZoom: 15, initialRotation: _heading),
              children: [
                TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: 'com.hawklink.soldier'),
                PolygonLayer(polygons: [if (_dangerZone.isNotEmpty) Polygon(points: _dangerZone, color: Colors.red.withOpacity(0.3), borderColor: Colors.redAccent, borderStrokeWidth: 4, isFilled: true)]),
                MarkerLayer(markers: [if (_hasFix) Marker(point: _myLocation, width: 40, height: 40, child: Transform.rotate(angle: (_heading * (pi / 180)), child: Icon(Icons.navigation, color: primaryColor, size: 35))), ..._targetMarkers]),
              ],
            ),
          ),

          if (isSOS) AnimatedBuilder(animation: _sosController, builder: (ctx, ch) => Container(color: Colors.red.withOpacity(0.3 * _sosController.value))),
          if (_isInDanger) Container(decoration: BoxDecoration(border: Border.all(color: Colors.red, width: 10))),

          SafeArea(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(12), margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), border: Border.all(color: isSOS ? Colors.red : primaryColor), borderRadius: BorderRadius.circular(8)),
                  child: Column(children: [
                    // --- LOGO REMOVED HERE ---
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("UPLINK: $_status", style: TextStyle(color: _socket != null ? primaryColor : Colors.red, fontWeight: FontWeight.bold, fontSize: 10)),
                      IconButton(icon: Icon(widget.isStealth ? Icons.visibility_off : Icons.visibility, color: primaryColor), onPressed: widget.onToggleStealth)
                    ]),

                    if (_socket == null) ...[
                      Row(children: [
                        Expanded(flex: 1, child: TextField(controller: _idController, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), decoration: const InputDecoration(labelText: "CALLSIGN"))),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: DropdownButtonFormField<String>(
                          value: _selectedRole,
                          dropdownColor: const Color(0xFF1E1E1E),
                          decoration: const InputDecoration(labelText: "ROLE"),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          items: _roles.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                          onChanged: (v) => setState(() => _selectedRole = v!),
                        )),
                      ]),
                      Row(children: [
                        Expanded(child: TextField(controller: _ipController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "COMMAND IP"))),
                        IconButton(icon: Icon(Icons.link, color: primaryColor), onPressed: _connect)
                      ])
                    ]
                    else Padding(padding: const EdgeInsets.only(top: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("${_idController.text} [$_selectedRole] | $_heartRate BPM", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      IconButton(icon: const Icon(Icons.link_off, color: Colors.red), onPressed: _disconnect)
                    ]))
                  ]),
                ),

                if (_pendingOrder != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: (widget.isStealth ? Colors.red[900]! : Colors.greenAccent).withOpacity(0.95), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.black, width: 2)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text("ORDER // ${_pendingOrder!['sender']}", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                      Text(_pendingOrder!['content'], style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 18)),
                      const SizedBox(height: 8),
                      SizedBox(width: double.infinity, child: ElevatedButton.icon(icon: const Icon(Icons.check_circle), label: const Text("COPY THAT"), style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white), onPressed: _acknowledgeOrder))
                    ]),
                  ),

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
          Positioned(top: 220, right: 16, child: FloatingActionButton(mini: true, backgroundColor: Colors.black, child: Icon(Icons.my_location, color: primaryColor), onPressed: () { if (_hasFix) _mapController.move(_myLocation, 17); })),
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