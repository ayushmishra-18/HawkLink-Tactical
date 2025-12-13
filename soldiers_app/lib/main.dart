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

  // CONFIGURABLE CONNECTION FIELDS
  final TextEditingController _ipController = TextEditingController(text: "10.0.2.2"); // Default IP
  final TextEditingController _idController = TextEditingController(text: "ALPHA-1"); // Default ID

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
  }

  @override
  void dispose() {
    _socket?.destroy();
    _heartbeatTimer?.cancel();
    _sosController.dispose();
    super.dispose();
  }

  // --- GPS LOGIC ---
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
        if (_hasFix && _mapController.camera.zoom < 5) {
          _mapController.move(_myLocation, 17);
        }
      }
    });
  }

  // --- NETWORKING ---
  Future<void> _connect() async {
    // Hide Keyboard
    FocusScope.of(context).unfocus();

    if (_idController.text.isEmpty || _ipController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ENTER UNIT ID AND IP")));
      return;
    }

    setState(() => _status = "SEARCHING...");
    try {
      _socket = await Socket.connect(_ipController.text, kPort, timeout: const Duration(seconds: 5));
      setState(() => _status = "SECURE UPLINK ESTABLISHED");

      _socket!.listen(
            (data) => _handleIncomingPacket(data),
        onDone: () {
          // Auto-reset UI on disconnect so user can reconnect easily
          if (mounted) {
            setState(() {
              _status = "CONNECTION LOST";
              _socket = null;
            });
          }
        },
        onError: (e) {
          if (mounted) {
            setState(() {
              _status = "ERROR: $e";
              _socket = null;
            });
          }
        },
      );

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (timer) => _sendHeartbeat());

    } catch (e) {
      setState(() {
        _status = "CONNECTION FAILED";
        _socket = null; // Ensure null so retry button shows
      });
    }
  }

  void _disconnect() {
    _socket?.destroy();
    setState(() {
      _socket = null;
      _status = "DISCONNECTED";
    });
  }

  void _handleIncomingPacket(List<int> data) {
    try {
      final str = utf8.decode(data).trim();
      if (str.isEmpty) return;
      final decrypted = _encrypter.decrypt64(str, iv: _iv);
      final json = jsonDecode(decrypted);

      if (json['type'] == 'CHAT' || json['type'] == 'MOVE_TO') {
        _onMessageReceived(json);
      }
    } catch (e) { debugPrint("Decryption Failed: $e"); }
  }

  void _onMessageReceived(Map<String, dynamic> msg) {
    setState(() {
      _messages.insert(0, {
        'time': DateTime.now(),
        'sender': msg['sender'] ?? 'CMD',
        'content': msg['content'] ?? 'DATA ERR',
        'type': msg['type']
      });
      _hasUnread = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.transparent, elevation: 0, duration: const Duration(seconds: 5),
          content: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.greenAccent.withOpacity(0.9), borderRadius: BorderRadius.circular(8)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("INCOMING // ${msg['sender'] ?? 'COMMAND'}", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 10)),
                Text(msg['content'] ?? "", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
          ),
        )
    );
  }

  void _sendHeartbeat() async {
    if (_socket == null) return;
    try {
      int batLevel = await _battery.batteryLevel;
      String currentStatus = _sosController.isAnimating ? "SOS" : "ACTIVE";

      _sendPacket({
        'type': 'STATUS',
        'id': _idController.text.toUpperCase(),
        'lat': _myLocation.latitude,
        'lng': _myLocation.longitude,
        'heading': 0,
        'bat': batLevel,
        'state': currentStatus
      });
    } catch (e) { debugPrint("Sensor Error: $e"); }
  }

  void _sendPacket(Map<String, dynamic> data) {
    if (_socket == null) return;
    try {
      final jsonStr = jsonEncode(data);
      final encrypted = _encrypter.encrypt(jsonStr, iv: _iv);
      _socket!.write(encrypted.base64);
    } catch (e) { debugPrint("Tx Error: $e"); }
  }

  // --- ACTIONS ---

  // 1. MARK TARGET
  void _markTarget() {
    if (!_hasFix) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("WAITING FOR GPS...")));
      return;
    }

    setState(() {
      _targetMarkers.add(
          Marker(
            point: _myLocation,
            width: 30, height: 30,
            child: const Icon(Icons.gps_fixed, color: Colors.redAccent, size: 30),
          )
      );
    });

    _sendPacket({
      'type': 'CHAT',
      'sender': _idController.text.toUpperCase(),
      'content': 'TARGET DESIGNATED AT ${_myLocation.latitude.toStringAsFixed(5)}, ${_myLocation.longitude.toStringAsFixed(5)}'
    });

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: Colors.redAccent,
        content: Text("TARGET COORDINATES SENT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
    ));
  }

  // 2. SOS
  void _activateSOS() {
    if (_sosController.isAnimating) {
      _sosController.stop(); _sosController.reset();
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': 'SOS CANCELLED'});
    } else {
      _sosController.repeat(reverse: true);
      _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '!!! SOS BEACON ACTIVATED !!!'});
      _sendHeartbeat();
    }
    setState(() {});
  }

  // 3. SITREP
  void _sendSitrep() {
    TextEditingController sitrepCtrl = TextEditingController();
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text("SEND SITREP", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
          content: TextField(
              controller: sitrepCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Report...",
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.greenAccent)),
              )
          ),
          actions: [
            TextButton(child: const Text("CANCEL", style: TextStyle(color: Colors.grey)), onPressed: () => Navigator.pop(ctx)),
            TextButton(
              child: const Text("TRANSMIT", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
              onPressed: () {
                if (sitrepCtrl.text.isNotEmpty) {
                  _sendPacket({'type': 'CHAT', 'sender': _idController.text.toUpperCase(), 'content': '[SITREP] ${sitrepCtrl.text}'});
                  Navigator.pop(ctx);
                }
              },
            ),
          ],
        )
    );
  }

  // 4. LOGS
  void _showCommsLog() {
    setState(() => _hasUnread = false);
    showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF111111),
        builder: (ctx) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("TACTICAL LOG", style: TextStyle(color: Colors.greenAccent, fontSize: 20, fontFamily: 'Courier', fontWeight: FontWeight.bold)),
              const Divider(color: Colors.greenAccent),
              Expanded(
                child: _messages.isEmpty
                    ? const Center(child: Text("NO ORDERS RECEIVED", style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                    itemCount: _messages.length,
                    itemBuilder: (c, i) {
                      final m = _messages[i];
                      return ListTile(
                        leading: Icon(m['type'] == 'MOVE_TO' ? Icons.directions_run : Icons.chat, color: Colors.greenAccent),
                        title: Text(m['sender'], style: const TextStyle(color: Colors.grey, fontSize: 10)),
                        subtitle: Text(m['content'], style: const TextStyle(color: Colors.white, fontSize: 14)),
                        trailing: Text(DateFormat('HH:mm').format(m['time']), style: const TextStyle(color: Colors.grey, fontSize: 10)),
                      );
                    }
                ),
              )
            ],
          ),
        )
    );
  }

  // --- UI ---
  @override
  Widget build(BuildContext context) {
    final bool isSOS = _sosController.isAnimating;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 1. MAP (Satellite View)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _hasFix ? _myLocation : const LatLng(40.7128, -74.0060),
              initialZoom: 15,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
            ),
            children: [
              TileLayer(
                  urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.hawklink.soldier'
              ),
              MarkerLayer(
                markers: [
                  if (_hasFix) Marker(
                      point: _myLocation,
                      width: 40, height: 40,
                      child: const Icon(Icons.navigation, color: Colors.blueAccent, size: 30)
                  ),
                  ..._targetMarkers
                ],
              ),
            ],
          ),

          // 2. SOS OVERLAY
          if (isSOS)
            AnimatedBuilder(animation: _sosController, builder: (ctx, child) => Container(color: Colors.red.withOpacity(0.3 * _sosController.value))),

          // 3. HUD CONTROLS
          SafeArea(
            child: Column(
              children: [
                // CONNECTIVITY BAR
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), border: Border.all(color: isSOS ? Colors.red : Colors.greenAccent), borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    children: [
                      // STATUS ROW
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("UPLINK: $_status", style: TextStyle(color: _socket != null ? Colors.greenAccent : Colors.red, fontWeight: FontWeight.bold, fontSize: 10)),
                        ],
                      ),

                      // LOGIN FORM (Only shown when disconnected)
                      if (_socket == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              // Unit ID Input
                              Expanded(
                                  flex: 1,
                                  child: TextField(
                                      controller: _idController,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.all(8), labelText: "CALLSIGN", labelStyle: TextStyle(color: Colors.grey, fontSize: 10))
                                  )
                              ),
                              const SizedBox(width: 8),
                              // IP Input
                              Expanded(
                                  flex: 2,
                                  child: TextField(
                                      controller: _ipController,
                                      style: const TextStyle(color: Colors.white),
                                      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.all(8), labelText: "COMMAND IP", labelStyle: TextStyle(color: Colors.grey, fontSize: 10))
                                  )
                              ),
                              IconButton(icon: const Icon(Icons.link), color: Colors.greenAccent, onPressed: _connect)
                            ],
                          ),
                        )
                      else
                      // CONNECTED STATE - SHOW RECONNECT OPTION
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text("CALLSIGN: ${_idController.text.toUpperCase()}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              // RECONNECT BUTTON
                              IconButton(
                                icon: const Icon(Icons.link_off, color: Colors.redAccent),
                                tooltip: "Disconnect / Reconnect",
                                onPressed: _disconnect,
                              )
                            ],
                          ),
                        )
                    ],
                  ),
                ),

                // UNREAD BANNER
                if (_hasUnread)
                  GestureDetector(
                    onTap: _showCommsLog,
                    child: Container(
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      decoration: BoxDecoration(color: Colors.greenAccent, borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 10)]),
                      child: const Text("NEW ORDER RECEIVED - TAP TO VIEW", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                  ),

                const Spacer(),

                // Bottom Controls
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.95), border: const Border(top: BorderSide(color: Colors.greenAccent, width: 2))),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: _TacticalButton(label: "SITREP", icon: Icons.assignment, color: Colors.blueAccent, onTap: _sendSitrep)),
                          const SizedBox(width: 8),
                          Expanded(child: _TacticalButton(label: "LOGS", icon: _hasUnread ? Icons.mark_chat_unread : Icons.history, color: _hasUnread ? Colors.greenAccent : Colors.white, onTap: _showCommsLog)),
                          const SizedBox(width: 8),
                          Expanded(child: _TacticalButton(label: "MARK", icon: Icons.gps_fixed, color: Colors.redAccent, onTap: _markTarget)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onLongPress: _activateSOS,
                        child: Container(
                          width: double.infinity, height: 50,
                          decoration: BoxDecoration(color: isSOS ? Colors.red : const Color(0xFF330000), border: Border.all(color: Colors.red, width: 2), borderRadius: BorderRadius.circular(4)),
                          child: Center(child: Text(isSOS ? "SOS ACTIVE" : "HOLD FOR SOS", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5))),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // RECENTER BUTTON
          Positioned(
            top: 180,
            right: 16,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.black,
              child: const Icon(Icons.my_location, color: Colors.greenAccent),
              onPressed: () { if (_hasFix) _mapController.move(_myLocation, 17); },
            ),
          ),
        ],
      ),
    );
  }
}

class _TacticalButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _TacticalButton({required this.label, required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.grey[900],
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(border: Border.all(color: color.withOpacity(0.7)), borderRadius: BorderRadius.circular(4)),
          child: Column(children: [Icon(icon, color: color, size: 28), const SizedBox(height: 4), Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12))]),
        ),
      ),
    );
  }
}