import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:encrypt/encrypt.dart' as enc;

// --- CONFIGURATION ---
const int kPort = 4444;
const String kPreSharedKey = 'HAWKLINK_TACTICAL_SECURE_KEY_256';
const String kFixedIV =      'HAWKLINK_IV_16ch';

// --- DATA MODELS ---
class SoldierUnit {
  String id;
  LatLng location;
  int battery;
  String status;
  DateTime lastSeen;
  Socket? socket;

  SoldierUnit({
    required this.id,
    required this.location,
    this.battery = 100,
    this.status = "IDLE",
    required this.lastSeen,
    this.socket,
  });
}

void main() {
  runApp(const CommanderApp());
}

class CommanderApp extends StatelessWidget {
  const CommanderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF050505),
        colorScheme: const ColorScheme.dark(primary: Colors.greenAccent),
      ),
      home: const CommanderDashboard(),
    );
  }
}

class CommanderDashboard extends StatefulWidget {
  const CommanderDashboard({super.key});

  @override
  State<CommanderDashboard> createState() => _CommanderDashboardState();
}

class _CommanderDashboardState extends State<CommanderDashboard> {
  // NETWORKING
  ServerSocket? _server;
  final List<SoldierUnit> _units = [];
  final List<String> _logs = [];
  List<String> _myIps = [];
  final TextEditingController _cmdController = TextEditingController();

  // ENCRYPTION
  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));

  // MAP STATE
  final MapController _mapController = MapController();
  String? _selectedUnitId;
  bool _showGrid = true;
  double _tilt = 0.0;
  double _rotation = 0.0;

  @override
  void initState() {
    super.initState();
    _startServer();
    _getLocalIps();
  }

  Future<void> _getLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      setState(() {
        _myIps = interfaces
            .map((i) => i.addresses.map((a) => a.address).join(", "))
            .toList();
      });
    } catch (e) {
      _log("SYS", "Failed to get IP: $e");
    }
  }

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort);
      _log("SYS", "SERVER ACTIVE ON PORT $kPort");

      _server!.listen((Socket client) {
        _log("NET", "NEW CONNECTION: ${client.remoteAddress.address}");

        client.listen(
              (data) => _handleData(client, data),
          onError: (e) => _removeClient(client),
          onDone: () => _removeClient(client),
        );
      });
    } catch (e) {
      _log("ERR", "BIND FAILED: $e");
    }
  }

  void _removeClient(Socket client) {
    setState(() {
      _units.removeWhere((u) => u.socket == client);
    });
  }

  void _handleData(Socket client, List<int> data) {
    try {
      final str = utf8.decode(data).trim();
      if (str.isEmpty) return;

      final decrypted = _encrypter.decrypt64(str, iv: _iv);
      final json = jsonDecode(decrypted);

      if (json['type'] == 'STATUS') {
        _updateUnit(client, json);
      } else if (json['type'] == 'CHAT') {
        _log(json['sender'], json['content']);
      }
    } catch (e) {
      // _log("ERR", "DECRYPT FAIL");
    }
  }

  void _updateUnit(Socket socket, Map<String, dynamic> data) {
    setState(() {
      final id = data['id'];
      final index = _units.indexWhere((u) => u.id == id);
      final newLoc = LatLng(data['lat'], data['lng']);

      if (index != -1) {
        _units[index].location = newLoc;
        _units[index].battery = data['bat'];
        _units[index].status = data['state'];
        _units[index].lastSeen = DateTime.now();
        _units[index].socket = socket;
      } else {
        _units.add(SoldierUnit(
          id: id,
          location: newLoc,
          battery: data['bat'],
          status: data['state'],
          lastSeen: DateTime.now(),
          socket: socket,
        ));
        _log("NET", "UNIT REGISTERED: $id");
      }
    });
  }

  void _log(String sender, String msg) {
    setState(() {
      _logs.insert(0, "[${DateFormat('HH:mm:ss').format(DateTime.now())}] $sender: $msg");
    });
  }

  void _broadcastOrder(String text) {
    if (text.isEmpty) return;

    final packet = _encryptPacket({'type': 'CHAT', 'sender': 'COMMAND', 'content': text});
    for (var u in _units) {
      try { u.socket?.write(packet); } catch (e) { /* ignore */ }
    }
    _log("CMD", "BROADCAST: $text");
    _cmdController.clear();
  }

  void _issueMoveOrder(LatLng dest) {
    if (_selectedUnitId == null) return;
    try {
      final unit = _units.firstWhere((u) => u.id == _selectedUnitId);
      final packet = _encryptPacket({
        'type': 'MOVE_TO',
        'sender': 'COMMAND',
        'content': "MOVE TO ${dest.latitude.toStringAsFixed(4)}, ${dest.longitude.toStringAsFixed(4)}",
        'lat': dest.latitude,
        'lng': dest.longitude
      });
      unit.socket?.write(packet);
      _log("CMD", "ORDER $unit.id -> MOVE");
    } catch(e) {/* ignore */}
  }

  String _encryptPacket(Map<String, dynamic> data) {
    return _encrypter.encrypt(jsonEncode(data), iv: _iv).base64;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // LEFT CONSOLE
          Container(
            width: 350,
            decoration: const BoxDecoration(
              color: Color(0xFF111111),
              border: Border(right: BorderSide(color: Color(0xFF333333))),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  color: const Color(0xFF0F380F),
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("HAWKLINK // TCP", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 20, fontFamily: 'Courier')),
                      const SizedBox(height: 5),
                      const Text("LOCAL SERVER ACTIVE", style: TextStyle(color: Colors.white, fontSize: 10)),
                      const SizedBox(height: 10),
                      SelectableText("IP: ${_myIps.isNotEmpty ? _myIps.first : 'Searching...'}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: ListView.builder(
                    itemCount: _units.length,
                    itemBuilder: (context, index) {
                      final u = _units[index];
                      bool isSelected = u.id == _selectedUnitId;
                      bool isSOS = u.status == "SOS";
                      return Container(
                        color: isSelected ? Colors.greenAccent.withOpacity(0.1) : null,
                        child: ListTile(
                          leading: Icon(Icons.shield, color: isSOS ? Colors.red : Colors.greenAccent),
                          title: Text(u.id, style: TextStyle(color: isSOS ? Colors.red : Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text("BAT: ${u.battery}% | ${u.status}", style: const TextStyle(color: Colors.grey, fontSize: 10)),
                          onTap: () {
                            setState(() => _selectedUnitId = u.id);
                            _mapController.move(u.location, 16);
                          },
                        ),
                      );
                    },
                  ),
                ),
                const Divider(color: Colors.grey),
                Expanded(
                  flex: 1,
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _logs.length,
                    itemBuilder: (c, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), child: Text(_logs[i], style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier', fontSize: 11))),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.black,
                  child: TextField(
                    controller: _cmdController,
                    style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier'),
                    decoration: InputDecoration(
                        hintText: "BROADCAST ORDER...",
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                            icon: const Icon(Icons.send, color: Colors.greenAccent),
                            onPressed: () => _broadcastOrder(_cmdController.text)
                        )
                    ),
                    onSubmitted: _broadcastOrder,
                  ),
                ),
              ],
            ),
          ),

          // RIGHT MAP
          Expanded(
            child: Stack(
              children: [
                // 3D TRANSFORM WIDGET
                Transform(
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.001) // Perspective depth
                    ..rotateX(-_tilt),      // FIXED: Negative value tilts the top AWAY from user
                  alignment: Alignment.center,
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: const LatLng(40.7128, -74.0060),
                      initialZoom: 14,
                      initialRotation: _rotation,
                      onLongPress: (tapPos, point) => _issueMoveOrder(point),
                    ),
                    children: [
                      TileLayer(
                          urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                          userAgentPackageName: 'com.hawklink.commander'
                      ),
                      if (_showGrid) _TacticalGrid(),
                      MarkerLayer(
                        markers: _units.map((u) => Marker(
                          point: u.location, width: 60, height: 60,
                          child: Transform.rotate(
                            angle: -_rotation * (math.pi / 180),
                            child: Column(children: [
                              Container(padding: const EdgeInsets.symmetric(horizontal: 4), color: Colors.black54, child: Text(u.id, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold))),
                              Icon(Icons.navigation, color: u.status == "SOS" ? Colors.red : Colors.cyanAccent, size: 24),
                            ]),
                          ),
                        )).toList(),
                      ),
                    ],
                  ),
                ),

                // HUD
                Positioned(
                  top: 20, right: 20,
                  child: Row(children: [
                    FloatingActionButton.small(backgroundColor: _showGrid ? Colors.greenAccent : Colors.grey, child: const Icon(Icons.grid_4x4), onPressed: () => setState(() => _showGrid = !_showGrid)),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: _tilt > 0 ? Colors.greenAccent : Colors.grey, child: const Icon(Icons.threed_rotation), onPressed: () => setState(() => _tilt = _tilt > 0 ? 0.0 : 0.6)),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: Colors.black54, child: const Icon(Icons.rotate_left, color: Colors.white), onPressed: () { setState(() => _rotation -= 45); _mapController.rotate(_rotation); }),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: Colors.black54, child: const Icon(Icons.rotate_right, color: Colors.white), onPressed: () { setState(() => _rotation += 45); _mapController.rotate(_rotation); }),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TacticalGrid extends StatelessWidget {
  @override Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _GridPainter()));
}
class _GridPainter extends CustomPainter {
  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.greenAccent.withOpacity(0.1)..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 100) canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (double y = 0; y < size.height; y += 100) canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}