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
  int bpm; // NEW: HEART RATE
  String status;
  DateTime lastSeen;
  Socket? socket;
  List<LatLng> pathHistory;

  SoldierUnit({
    required this.id,
    required this.location,
    this.battery = 100,
    this.bpm = 75,
    this.status = "IDLE",
    required this.lastSeen,
    this.socket,
    List<LatLng>? history,
  }) : pathHistory = history ?? [];
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
  ServerSocket? _server;
  final List<SoldierUnit> _units = [];
  final List<String> _logs = [];
  List<String> _myIps = [];
  final TextEditingController _cmdController = TextEditingController();

  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));

  final MapController _mapController = MapController();
  String? _selectedUnitId;
  bool _showGrid = true;
  bool _showTrails = true;
  double _tilt = 0.0;
  double _rotation = 0.0;

  bool _isDrawingMode = false;
  List<LatLng> _tempDrawPoints = [];
  List<LatLng> _activeDangerZone = [];

  // NEW: RULER TOOL
  LatLng? _rulerStart;
  LatLng? _rulerEnd;

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
        _myIps = interfaces.map((i) => i.addresses.map((a) => a.address).join(", ")).toList();
      });
    } catch (e) { }
  }

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort);
      _log("SYS", "SERVER ACTIVE ON PORT $kPort");
      _server!.listen((Socket client) {
        client.listen((data) => _handleData(client, data), onError: (e) => _removeClient(client), onDone: () => _removeClient(client));
      });
    } catch (e) { _log("ERR", "BIND FAILED: $e"); }
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
      } else if (json['type'] == 'CHAT' || json['type'] == 'ACK') { // Handle ACK
        _log(json['sender'], json['content']);
      }
    } catch (e) { }
  }

  void _updateUnit(Socket socket, Map<String, dynamic> data) {
    setState(() {
      final id = data['id'];
      final index = _units.indexWhere((u) => u.id == id);
      final newLoc = LatLng(data['lat'], data['lng']);

      if (index != -1) {
        _units[index].location = newLoc;
        _units[index].battery = data['bat'];
        _units[index].bpm = data['bpm'] ?? 75; // Update BPM
        _units[index].status = data['state'];
        _units[index].lastSeen = DateTime.now();
        _units[index].socket = socket;

        if (_units[index].pathHistory.isEmpty || const Distance().as(LengthUnit.Meter, _units[index].pathHistory.last, newLoc) > 5) {
          _units[index].pathHistory.add(newLoc);
          if (_units[index].pathHistory.length > 500) _units[index].pathHistory.removeAt(0);
        }
      } else {
        _units.add(SoldierUnit(id: id, location: newLoc, battery: data['bat'], bpm: data['bpm']??75, status: data['state'], lastSeen: DateTime.now(), socket: socket, history: [newLoc]));
        _log("NET", "UNIT REGISTERED: $id");
      }
    });
  }

  void _log(String sender, String msg) {
    setState(() {
      bool isAck = msg.contains("RECEIVED") || msg.contains("COPY");
      String prefix = isAck ? "✅ " : "";
      _logs.insert(0, "$prefix[${DateFormat('HH:mm:ss').format(DateTime.now())}] $sender: $msg");
    });
  }

  void _broadcastOrder(String text) {
    if (text.isEmpty) return;
    final packet = _encryptPacket({'type': 'CHAT', 'sender': 'COMMAND', 'content': text});
    for (var u in _units) { try { u.socket?.write(packet); } catch (e) { } }
    _log("CMD", "BROADCAST: $text");
    _cmdController.clear();
  }

  void _issueMoveOrder(LatLng dest) {
    if (_isDrawingMode) return;
    if (_selectedUnitId == null) {
      // If no unit selected, start ruler tool
      setState(() => _rulerStart = dest);
      return;
    }

    // Normal Move Order
    try {
      final unit = _units.firstWhere((u) => u.id == _selectedUnitId);
      final packet = _encryptPacket({'type': 'MOVE_TO', 'sender': 'COMMAND', 'content': "MOVE TO ${dest.latitude.toStringAsFixed(4)}, ${dest.longitude.toStringAsFixed(4)}", 'lat': dest.latitude, 'lng': dest.longitude});
      unit.socket?.write(packet);
      _log("CMD", "ORDER $unit.id -> MOVE");
    } catch(e) {/* ignore */}
  }

  void _onMapTap(TapPosition tapPos, LatLng point) {
    if (_isDrawingMode) {
      setState(() => _tempDrawPoints.add(point));
    } else {
      setState(() {
        _selectedUnitId = null;
        if (_rulerStart != null) {
          _rulerEnd = point;
          double dist = const Distance().as(LengthUnit.Meter, _rulerStart!, _rulerEnd!);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("DISTANCE: ${dist.toStringAsFixed(1)}m")));
          // Reset after short delay
          Future.delayed(const Duration(seconds: 4), () => setState(() { _rulerStart = null; _rulerEnd = null; }));
        }
      });
    }
  }

  // --- DRAWING LOGIC ---
  void _toggleDrawingMode() {
    setState(() { _isDrawingMode = !_isDrawingMode; _tempDrawPoints = []; });
    if (_isDrawingMode) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("DRAW MODE ACTIVE"), backgroundColor: Colors.orange));
  }

  void _deployCustomZone() {
    if (_tempDrawPoints.length < 3) return;
    setState(() { _activeDangerZone = List.from(_tempDrawPoints); _isDrawingMode = false; _tempDrawPoints = []; });
    List<List<double>> points = _activeDangerZone.map((p) => [p.latitude, p.longitude]).toList();
    final packet = _encryptPacket({'type': 'ZONE', 'sender': 'COMMAND', 'points': points});
    for (var u in _units) { try { u.socket?.write(packet); } catch (e) {} }
    _log("CMD", "ZONE DEPLOYED");
  }

  void _clearZone() {
    setState(() { _activeDangerZone = []; _tempDrawPoints = []; });
    final packet = _encryptPacket({'type': 'ZONE', 'sender': 'COMMAND', 'points': []});
    for (var u in _units) { try { u.socket?.write(packet); } catch (e) {} }
    _log("CMD", "ZONE CLEARED");
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
            decoration: const BoxDecoration(color: Color(0xFF111111), border: Border(right: BorderSide(color: Color(0xFF333333)))),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(20), color: const Color(0xFF0F380F), width: double.infinity,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text("HAWKLINK // TCP", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 20, fontFamily: 'Courier')),
                    const SizedBox(height: 5), const Text("LOCAL SERVER ACTIVE", style: TextStyle(color: Colors.white, fontSize: 10)),
                    const SizedBox(height: 10), SelectableText("IP: ${_myIps.isNotEmpty ? _myIps.first : 'Searching...'}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ]),
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
                          // UPDATED SUBTITLE WITH BPM
                          subtitle: Text("BAT: ${u.battery}% | BPM: ${u.bpm} | ${u.status}", style: const TextStyle(color: Colors.grey, fontSize: 10)),
                          onTap: () { setState(() => _selectedUnitId = u.id); _mapController.move(u.location, 16); },
                        ),
                      );
                    },
                  ),
                ),
                const Divider(color: Colors.grey),
                Expanded(
                  flex: 1,
                  child: ListView.builder(
                    reverse: true, itemCount: _logs.length,
                    itemBuilder: (c, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), child: Text(_logs[i], style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier', fontSize: 11))),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(8), color: Colors.black,
                  child: TextField(
                    controller: _cmdController,
                    style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier'),
                    decoration: InputDecoration(hintText: "BROADCAST ORDER...", hintStyle: const TextStyle(color: Colors.grey), border: const OutlineInputBorder(), suffixIcon: IconButton(icon: const Icon(Icons.send, color: Colors.greenAccent), onPressed: () => _broadcastOrder(_cmdController.text))),
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
                Transform(
                  transform: Matrix4.identity()..setEntry(3, 2, 0.001)..rotateX(-_tilt),
                  alignment: Alignment.center,
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: const LatLng(40.7128, -74.0060),
                      initialZoom: 14,
                      initialRotation: _rotation,
                      onTap: _onMapTap,
                      onLongPress: (tapPos, point) => _issueMoveOrder(point),
                    ),
                    children: [
                      TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: 'com.hawklink.commander'),

                      if (_activeDangerZone.isNotEmpty) PolygonLayer(polygons: [Polygon(points: _activeDangerZone, color: Colors.red.withOpacity(0.3), borderColor: Colors.redAccent, borderStrokeWidth: 4, isFilled: true)]),
                      if (_isDrawingMode && _tempDrawPoints.isNotEmpty) ...[
                        PolylineLayer(polylines: [Polyline(points: _tempDrawPoints, color: Colors.orangeAccent, strokeWidth: 3.0, isDotted: true), if (_tempDrawPoints.length > 2) Polyline(points: [_tempDrawPoints.last, _tempDrawPoints.first], color: Colors.orangeAccent.withOpacity(0.5), strokeWidth: 1.0, isDotted: true)]),
                        MarkerLayer(markers: _tempDrawPoints.map((p) => Marker(point: p, width: 10, height: 10, child: Container(decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle)))).toList()),
                      ],

                      // RULER LINE
                      if (_rulerStart != null && _rulerEnd != null)
                        PolylineLayer(polylines: [Polyline(points: [_rulerStart!, _rulerEnd!], color: Colors.blueAccent, strokeWidth: 4.0)]),

                      if (_showGrid) _TacticalGrid(),
                      if (_showTrails) PolylineLayer(polylines: _units.map((u) => Polyline(points: u.pathHistory, strokeWidth: 5.0, color: u.status == "SOS" ? Colors.red : Colors.greenAccent, isDotted: true)).toList()),
                      MarkerLayer(markers: _units.map((u) => Marker(point: u.location, width: 60, height: 60, child: Transform.rotate(angle: -_rotation * (math.pi / 180), child: Column(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 4), color: Colors.black54, child: Text(u.id, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold))), Icon(Icons.navigation, color: u.status == "SOS" ? Colors.red : Colors.cyanAccent, size: 24)])))).toList()),
                    ],
                  ),
                ),
                Positioned(
                  top: 20, right: 20,
                  child: Row(children: [
                    if (_isDrawingMode) ...[FloatingActionButton.small(backgroundColor: Colors.green, onPressed: _deployCustomZone, child: const Icon(Icons.check)), const SizedBox(width: 8), FloatingActionButton.small(backgroundColor: Colors.red, onPressed: _toggleDrawingMode, child: const Icon(Icons.close)), const SizedBox(width: 20)] else ...[FloatingActionButton.small(backgroundColor: _activeDangerZone.isNotEmpty ? Colors.red : Colors.grey, onPressed: _activeDangerZone.isNotEmpty ? _clearZone : _toggleDrawingMode, child: Icon(_activeDangerZone.isNotEmpty ? Icons.delete_forever : Icons.edit)), const SizedBox(width: 8)],
                    FloatingActionButton.small(backgroundColor: _showGrid ? Colors.greenAccent : Colors.grey, child: const Icon(Icons.grid_4x4), onPressed: () => setState(() => _showGrid = !_showGrid)),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: _showTrails ? Colors.orangeAccent : Colors.grey, child: const Icon(Icons.timeline), onPressed: () => setState(() => _showTrails = !_showTrails)),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: _tilt > 0 ? Colors.greenAccent : Colors.grey, child: const Icon(Icons.threed_rotation), onPressed: () => setState(() => _tilt = _tilt > 0 ? 0.0 : 0.6)),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: Colors.black54, child: const Icon(Icons.rotate_left, color: Colors.white), onPressed: () { setState(() => _rotation -= 45); _mapController.rotate(_rotation); }),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(backgroundColor: Colors.black54, child: const Icon(Icons.rotate_right, color: Colors.white), onPressed: () { setState(() => _rotation += 45); _mapController.rotate(_rotation); }),
                  ]),
                ),
                if (_isDrawingMode) Positioned(top: 80, right: 20, child: Container(padding: const EdgeInsets.all(8), color: Colors.black87, child: const Text("TAP MAP TO PLOT POINTS", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)))),
                if (_rulerStart != null && _rulerEnd == null) Positioned(top: 80, right: 20, child: Container(padding: const EdgeInsets.all(8), color: Colors.blue[900], child: const Text("RULER ACTIVE: TAP END POINT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
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