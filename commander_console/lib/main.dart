import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

// --- CONFIGURATION ---
const int kPort = 4444;
const String kPreSharedKey = 'HAWKLINK_TACTICAL_SECURE_KEY_256';
const String kFixedIV =      'HAWKLINK_IV_16ch';

// --- THEME ---
const Color kCyan = Color(0xFF00F0FF);
const Color kRed = Color(0xFFFF2A6D);
const Color kGreen = Color(0xFF05FFA1);
const Color kBlack = Color(0xFF050505);

class SoldierUnit {
  String id;
  String role;
  LatLng location;
  double heading;
  int battery;
  int bpm;
  String status;
  DateTime lastSeen;
  Socket? socket;
  List<LatLng> pathHistory;

  SoldierUnit({
    required this.id,
    this.role = "ASSAULT",
    required this.location,
    this.heading = 0.0,
    this.battery = 100,
    this.bpm = 75,
    this.status = "IDLE",
    required this.lastSeen,
    this.socket,
    List<LatLng>? history,
  }) : pathHistory = history ?? [];
}

class TacticalWaypoint {
  String id;
  String type; // RALLY, ENEMY, MED, LZ
  LatLng location;
  DateTime created;

  TacticalWaypoint({required this.id, required this.type, required this.location, required this.created});

  Map<String, dynamic> toJson() => {'id': id, 'type': type, 'lat': location.latitude, 'lng': location.longitude, 'time': created.toIso8601String()};
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
        scaffoldBackgroundColor: kBlack,
        colorScheme: const ColorScheme.dark(primary: kCyan, surface: Color(0xFF101015)),
        textTheme: const TextTheme(bodyMedium: TextStyle(fontFamily: 'Courier')),
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

class _CommanderDashboardState extends State<CommanderDashboard> with TickerProviderStateMixin {
  ServerSocket? _server;
  final List<SoldierUnit> _units = [];
  final List<Map<String, dynamic>> _logs = [];
  final List<TacticalWaypoint> _waypoints = [];
  List<String> _myIps = [];
  final TextEditingController _cmdController = TextEditingController();

  // TCP BUFFERING
  final Map<Socket, List<int>> _clientBuffers = {};

  final AudioPlayer _sfxPlayer = AudioPlayer();
  final AudioPlayer _alertPlayer = AudioPlayer();

  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));

  final MapController _mapController = MapController();
  late AnimationController _pulseController;
  String? _selectedUnitId;
  bool _showGrid = true;
  bool _showTrails = true;
  double _tilt = 0.0;
  double _rotation = 0.0;

  // MODES
  bool _isDrawingMode = false;
  String? _placingWaypointType;
  bool _isDeleteWaypointMode = false;
  List<LatLng> _tempDrawPoints = [];
  List<LatLng> _activeDangerZone = [];

  @override
  void initState() {
    super.initState();
    _startServer();
    _getLocalIps();
    _loadLogs();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }

  @override
  void dispose() {
    _sfxPlayer.dispose();
    _alertPlayer.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<File> _getLogFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/hawklink_logs.txt');
  }

  Future<void> _loadLogs() async {
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        final contents = await file.readAsLines();
        setState(() {
          for (var line in contents.reversed.take(100)) {
            _logs.add({'text': line, 'image': null});
          }
        });
      }
    } catch (e) {}
  }

  Future<void> _saveLog(String logEntry) async {
    try {
      final file = await _getLogFile();
      await file.writeAsString('$logEntry\n', mode: FileMode.append);
    } catch (e) {}
  }

  Future<String> _saveImageToDisk(String sender, String base64Data) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final intelDir = Directory('${directory.path}/HawkLink_Intel');
      if (!await intelDir.exists()) await intelDir.create();
      String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      File imageFile = File('${intelDir.path}/IMG_${sender}_$timestamp.jpg');
      await imageFile.writeAsBytes(base64Decode(base64Data));
      return imageFile.path;
    } catch (e) {
      debugPrint("IMAGE SAVE ERROR: $e");
      return "";
    }
  }

  Future<void> _playSfx(String filename) async {
    try {
      if (_sfxPlayer.state == PlayerState.playing) await _sfxPlayer.stop();
      _sfxPlayer.setVolume(1.0);
      await _sfxPlayer.play(AssetSource('sounds/$filename'));
    } catch (e) { debugPrint("AUDIO ERROR: $e"); }
  }

  Future<void> _playAlert(String filename) async {
    try {
      if (_alertPlayer.state == PlayerState.playing) await _alertPlayer.stop();
      _alertPlayer.setVolume(1.0);
      await _alertPlayer.play(AssetSource('sounds/$filename'));
    } catch (e) { debugPrint("AUDIO ERROR: $e"); }
  }

  Future<void> _getLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      setState(() {
        _myIps = interfaces.map((i) => i.addresses.map((a) => a.address).join(", ")).toList();
      });
    } catch (e) {}
  }

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort);
      _log("SYS", "SERVER ONLINE | PORT $kPort");
      _playSfx('connect.mp3');
      _server!.listen((Socket client) {
        _log("NET", "UPLINK ESTABLISHED: ${client.remoteAddress.address}");
        _clientBuffers[client] = [];
        client.listen(
              (data) => _handleData(client, data),
          onError: (e) => _removeClient(client),
          onDone: () => _removeClient(client),
        );
      });
    } catch (e) { _log("ERR", "BIND FAILURE: $e"); }
  }

  void _removeClient(Socket client) {
    setState(() {
      _units.removeWhere((u) => u.socket == client);
      _clientBuffers.remove(client);
    });
  }

  // --- BUFFERED DATA HANDLING (FIXES IMAGES) ---
  void _handleData(Socket client, List<int> data) {
    if (!_clientBuffers.containsKey(client)) {
      _clientBuffers[client] = [];
    }
    _clientBuffers[client]!.addAll(data);

    List<int> buffer = _clientBuffers[client]!;
    while (true) {
      int index = buffer.indexOf(10); // Find \n delimiter
      if (index == -1) break;

      List<int> packetBytes = buffer.sublist(0, index);
      buffer = buffer.sublist(index + 1);
      _clientBuffers[client] = buffer;

      _processPacket(client, packetBytes);
    }
  }

  void _processPacket(Socket client, List<int> packetBytes) async {
    try {
      final str = utf8.decode(packetBytes).trim();
      if (str.isEmpty) return;

      final decrypted = _encrypter.decrypt64(str, iv: _iv);
      final json = jsonDecode(decrypted);

      if (json['type'] == 'STATUS') {
        _updateUnit(client, json);
      } else if (json['type'] == 'CHAT' || json['type'] == 'ACK') {
        _log(json['sender'], json['content']);
        if(json['content'].toString().contains("SOS")) _playAlert('alert.mp3');
        if(json['type'] == 'ACK') _playSfx('connect.mp3');
      } else if (json['type'] == 'IMAGE') {
        String sender = json['sender'];
        String base64Content = json['content'];
        String path = await _saveImageToDisk(sender, base64Content);
        _log(sender, "📸 INTEL RECEIVED", imagePath: path);
        _playSfx('connect.mp3');
      }
    } catch (e) { debugPrint("PACKET ERROR: $e"); }
  }

  void _updateUnit(Socket socket, Map<String, dynamic> data) {
    setState(() {
      final id = data['id'];
      final index = _units.indexWhere((u) => u.id == id);
      final newLoc = LatLng(data['lat'], data['lng']);

      if (index != -1) {
        _units[index].location = newLoc;
        _units[index].heading = (data['head'] ?? 0.0).toDouble();
        _units[index].role = data['role'] ?? "ASSAULT";
        _units[index].battery = data['bat'];
        _units[index].bpm = data['bpm'] ?? 75;
        _units[index].status = data['state'];
        _units[index].lastSeen = DateTime.now();
        _units[index].socket = socket;

        if (_units[index].pathHistory.isEmpty || const Distance().as(LengthUnit.Meter, _units[index].pathHistory.last, newLoc) > 5) {
          _units[index].pathHistory.add(newLoc);
          if (_units[index].pathHistory.length > 500) _units[index].pathHistory.removeAt(0);
        }
      } else {
        _units.add(SoldierUnit(
            id: id, location: newLoc, role: data['role'] ?? "ASSAULT",
            battery: data['bat'], bpm: data['bpm']??75, status: data['state'],
            lastSeen: DateTime.now(), socket: socket, history: [newLoc]
        ));
        _log("NET", "UNIT REGISTERED: $id");
        _playSfx('connect.mp3');
      }
    });
  }

  void _log(String sender, String msg, {String? imagePath}) {
    String timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    bool isAck = msg.contains("RECEIVED") || msg.contains("COPY");
    String prefix = isAck ? "✅ " : "";
    String textEntry = "$prefix[$timestamp] $sender: $msg";
    setState(() {
      _logs.insert(0, {'text': textEntry, 'image': imagePath});
    });
    _saveLog(textEntry + (imagePath != null ? " [IMAGE SAVED]" : ""));
  }

  void _broadcastOrder(String text) {
    if (text.isEmpty) return;
    final packet = _encryptPacket({'type': 'CHAT', 'sender': 'COMMAND', 'content': text});
    final delimitedPacket = utf8.encode("$packet\n");
    for (var u in _units) { try { u.socket?.add(delimitedPacket); } catch (e) { } }
    _log("CMD", "BROADCAST: $text");
    _cmdController.clear();
    _playSfx('order.mp3');
  }

  void _issueMoveOrder(LatLng dest) {
    if (_isDrawingMode || _placingWaypointType != null || _isDeleteWaypointMode || _selectedUnitId == null) return;
    try {
      final unit = _units.firstWhere((u) => u.id == _selectedUnitId);
      final packet = _encryptPacket({'type': 'MOVE_TO', 'sender': 'COMMAND', 'content': "MOVE TO ${dest.latitude.toStringAsFixed(4)}, ${dest.longitude.toStringAsFixed(4)}", 'lat': dest.latitude, 'lng': dest.longitude});
      unit.socket?.add(utf8.encode("$packet\n"));
      _log("CMD", "VECTOR ASSIGNED: $unit.id");
      _playSfx('order.mp3');
    } catch(e) {}
  }

  // --- MAP INTERACTION ---
  void _onMapTap(TapPosition tapPos, LatLng point) {
    if (_isDeleteWaypointMode) {
      _removeWaypointNear(point);
      setState(() => _isDeleteWaypointMode = false);
      return;
    }
    if (_placingWaypointType != null) {
      _deployWaypoint(point, _placingWaypointType!);
      setState(() => _placingWaypointType = null);
      return;
    }
    if (_isDrawingMode) {
      setState(() => _tempDrawPoints.add(point));
      return;
    }
    setState(() => _selectedUnitId = null);
  }

  void _deployWaypoint(LatLng point, String type) {
    String id = "${type}_${DateTime.now().millisecondsSinceEpoch}";
    TacticalWaypoint wp = TacticalWaypoint(id: id, type: type, location: point, created: DateTime.now());
    setState(() => _waypoints.add(wp));
    final packet = _encryptPacket({'type': 'WAYPOINT', 'action': 'ADD', 'data': wp.toJson()});
    final delimitedPacket = utf8.encode("$packet\n");
    for (var u in _units) { try { u.socket?.add(delimitedPacket); } catch (e) {} }
    _log("CMD", "WAYPOINT DEPLOYED: $type");
    _playSfx('order.mp3');
  }

  void _removeWaypointNear(LatLng point) {
    try {
      final nearest = _waypoints.firstWhere((wp) => const Distance().as(LengthUnit.Meter, wp.location, point) < 200);
      setState(() => _waypoints.remove(nearest));
      final packet = _encryptPacket({'type': 'WAYPOINT', 'action': 'REMOVE', 'id': nearest.id});
      final delimitedPacket = utf8.encode("$packet\n");
      for (var u in _units) { try { u.socket?.add(delimitedPacket); } catch (e) {} }
      _log("CMD", "WAYPOINT REMOVED");
      _playSfx('connect.mp3');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("NO WAYPOINT NEARBY")));
    }
  }

  void _toggleDrawingMode() {
    setState(() { _isDrawingMode = !_isDrawingMode; _tempDrawPoints = []; });
  }

  void _deployCustomZone() {
    if (_tempDrawPoints.length < 3) return;
    setState(() { _activeDangerZone = List.from(_tempDrawPoints); _isDrawingMode = false; _tempDrawPoints = []; });
    List<List<double>> points = _activeDangerZone.map((p) => [p.latitude, p.longitude]).toList();
    final packet = _encryptPacket({'type': 'ZONE', 'sender': 'COMMAND', 'points': points});
    final delimitedPacket = utf8.encode("$packet\n");
    for (var u in _units) { try { u.socket?.add(delimitedPacket); } catch (e) {} }
    _log("CMD", "ZONE DEPLOYED");
    _playAlert('alert.mp3');
  }

  void _clearZone() {
    setState(() { _activeDangerZone = []; _tempDrawPoints = []; });
    final packet = _encryptPacket({'type': 'ZONE', 'sender': 'COMMAND', 'points': []});
    final delimitedPacket = utf8.encode("$packet\n");
    for (var u in _units) { try { u.socket?.add(delimitedPacket); } catch (e) {} }
    _log("CMD", "ZONE CLEARED");
  }

  String _encryptPacket(Map<String, dynamic> data) => _encrypter.encrypt(jsonEncode(data), iv: _iv).base64;

  IconData _getRoleIcon(String role) {
    switch (role) {
      case "MEDIC": return Icons.medical_services;
      case "SCOUT": return Icons.visibility;
      case "SNIPER": return Icons.gps_fixed;
      case "ENGINEER": return Icons.build;
      default: return Icons.shield;
    }
  }

  // --- UI COMPONENTS ---
  void _showImagePreview(String path) {
    showDialog(context: context, builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Stack(alignment: Alignment.center, children: [
        Image.file(File(path)),
        Positioned(top: 10, right: 10, child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 30), onPressed: () => Navigator.pop(ctx)))
      ]),
    ));
  }

  Widget _buildGlassPanel({required Widget child, double width = 350}) {
    return ClipRect(
      child: Container(
        width: width,
        decoration: BoxDecoration(color: const Color(0xFF101015).withOpacity(0.85), border: const Border(right: BorderSide(color: Color(0xFF333333)))),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10), child: child),
      ),
    );
  }

  Widget _buildTacticalHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(color: Color(0xFF0F380F), border: Border(bottom: BorderSide(color: kGreen, width: 2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("HAWKLINK // C2", style: TextStyle(color: kGreen, fontWeight: FontWeight.bold, fontSize: 24, letterSpacing: 3.0, fontFamily: 'Courier')),
        const SizedBox(height: 5),
        Row(children: [Container(width: 8, height: 8, decoration: const BoxDecoration(color: kGreen, shape: BoxShape.circle)), const SizedBox(width: 8), const Text("SECURE UPLINK: ACTIVE", style: TextStyle(color: kCyan, fontSize: 10, letterSpacing: 1.5))]),
        const SizedBox(height: 10),
        Text("IP: ${_myIps.isNotEmpty ? _myIps.first : 'SCANNING...'}", style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              _buildGlassPanel(
                child: Column(
                  children: [
                    _buildTacticalHeader(),
                    Expanded(
                      flex: 2,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: 10),
                        itemCount: _units.length,
                        itemBuilder: (context, index) {
                          final u = _units[index];
                          bool isSelected = u.id == _selectedUnitId;
                          bool isSOS = u.status == "SOS";
                          Color statusColor = isSOS ? kRed : kGreen;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: isSelected ? kCyan.withOpacity(0.1) : Colors.transparent, border: Border.all(color: isSelected ? kCyan : Colors.white10), borderRadius: BorderRadius.circular(4)),
                            child: ListTile(
                              leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: statusColor.withOpacity(0.1), border: Border.all(color: statusColor.withOpacity(0.5)), shape: BoxShape.circle), child: Icon(_getRoleIcon(u.role), color: statusColor, size: 20)),
                              title: Text("${u.id}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Courier')),
                              subtitle: Row(children: [Icon(Icons.battery_std, size: 12, color: u.battery < 20 ? kRed : kGreen), Text("${u.battery}% ", style: const TextStyle(color: Colors.grey, fontSize: 10)), const SizedBox(width: 8), Icon(Icons.monitor_heart, size: 12, color: u.bpm > 100 ? kRed : kCyan), Text("${u.bpm}", style: const TextStyle(color: Colors.grey, fontSize: 10))]),
                              trailing: Text(u.role, style: TextStyle(color: kCyan.withOpacity(0.7), fontSize: 9, fontWeight: FontWeight.bold)),
                              onTap: () { setState(() => _selectedUnitId = u.id); _mapController.move(u.location, 17); },
                            ),
                          );
                        },
                      ),
                    ),
                    Container(
                      height: 200, decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.white10))),
                      child: ListView.builder(reverse: true, itemCount: _logs.length, padding: const EdgeInsets.all(8), itemBuilder: (c, i) {
                        final logItem = _logs[i];
                        return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(logItem['text'], style: const TextStyle(color: kGreen, fontFamily: 'Courier', fontSize: 10)), if (logItem['image'] != null && logItem['image'].isNotEmpty) GestureDetector(onTap: () => _showImagePreview(logItem['image']), child: Container(margin: const EdgeInsets.only(top: 4), height: 100, width: 150, decoration: BoxDecoration(border: Border.all(color: kCyan), borderRadius: BorderRadius.circular(4)), child: Image.file(File(logItem['image']), fit: BoxFit.cover)))]));
                      }),
                    ),
                    Container(padding: const EdgeInsets.all(12), decoration: const BoxDecoration(border: Border(top: BorderSide(color: kCyan, width: 1))), child: TextField(controller: _cmdController, style: const TextStyle(color: kCyan, fontFamily: 'Courier'), cursorColor: kCyan, decoration: const InputDecoration(hintText: "ENTER COMMAND...", hintStyle: TextStyle(color: Colors.white24), border: InputBorder.none, isDense: true), onSubmitted: _broadcastOrder)),
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
                        options: MapOptions(initialCenter: const LatLng(40.7128, -74.0060), initialZoom: 14, initialRotation: _rotation, onTap: _onMapTap, onLongPress: (tapPos, point) => _issueMoveOrder(point)),
                        children: [
                          TileLayer(urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', userAgentPackageName: 'com.hawklink.commander'),
                          if (_activeDangerZone.isNotEmpty) PolygonLayer(polygons: [Polygon(points: _activeDangerZone, color: kRed.withOpacity(0.3), borderColor: kRed, borderStrokeWidth: 2, isFilled: true)]),
                          if (_isDrawingMode && _tempDrawPoints.isNotEmpty) ...[PolylineLayer(polylines: [Polyline(points: _tempDrawPoints, color: Colors.orange, strokeWidth: 2, isDotted: true), if(_tempDrawPoints.length > 2) Polyline(points: [_tempDrawPoints.last, _tempDrawPoints.first], color: Colors.orange, strokeWidth: 2, isDotted: true)]), MarkerLayer(markers: _tempDrawPoints.map((p) => Marker(point: p, width: 10, height: 10, child: Container(decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle)))).toList())],
                          if (_showGrid) _TacticalGrid(),
                          if (_showTrails) PolylineLayer(polylines: _units.map((u) => Polyline(points: u.pathHistory, strokeWidth: 3.0, color: u.status == "SOS" ? kRed : kGreen, isDotted: true)).toList()),
                          PolygonLayer(polygons: _units.map((u) => Polygon(points: _createVisionCone(u.location, u.heading), color: kCyan.withOpacity(0.15), isFilled: true, borderStrokeWidth: 0)).toList()),

                          // WAYPOINTS LAYER
                          MarkerLayer(
                            markers: _waypoints.map((wp) => Marker(
                              point: wp.location,
                              width: 60, height: 60,
                              child: Column(children: [
                                Icon(
                                  wp.type == "RALLY" ? Icons.flag :
                                  wp.type == "ENEMY" ? Icons.warning :
                                  wp.type == "MED" ? Icons.local_hospital : Icons.flight_land,
                                  color: wp.type == "ENEMY" ? kRed : (wp.type == "MED" ? Colors.white : Colors.blueAccent),
                                  size: 32,
                                ),
                                Text(wp.type, style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold, backgroundColor: Colors.black.withOpacity(0.5)))
                              ]),
                            )).toList(),
                          ),

                          MarkerLayer(markers: _units.map((u) {
                            bool isSelected = u.id == _selectedUnitId;
                            return Marker(
                              point: u.location, width: 100, height: 100,
                              child: Transform.rotate(angle: -_rotation * (math.pi / 180), child: Stack(alignment: Alignment.center, children: [
                                if (u.status == "SOS") ScaleTransition(scale: _pulseController, child: Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kRed.withOpacity(0.5), width: 2)))),
                                if (isSelected) RotationTransition(turns: _pulseController, child: Container(width: 60, height: 60, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kCyan, width: 2, style: BorderStyle.solid)))),
                                Column(mainAxisSize: MainAxisSize.min, children: [Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), borderRadius: BorderRadius.circular(4), border: Border.all(color: isSelected ? kCyan : Colors.white24)), child: Text(u.id, style: TextStyle(color: isSelected ? kCyan : Colors.white, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'Courier'))), const SizedBox(height: 4), Transform.rotate(angle: (u.heading * (math.pi / 180)), child: Icon(_getRoleIcon(u.role), color: u.status == "SOS" ? kRed : kCyan, size: 28))]),
                              ])),
                            );
                          }).toList(),
                          ),
                        ],
                      ),
                    ),
                    Positioned(top: 20, right: 20, child: _buildGlassPanel(width: 60, child: Column(children: [const SizedBox(height: 10), if (_isDrawingMode) ...[_HudBtn(icon: Icons.check, color: kGreen, onTap: _deployCustomZone), _HudBtn(icon: Icons.close, color: kRed, onTap: _toggleDrawingMode)] else ...[_HudBtn(icon: _activeDangerZone.isNotEmpty ? Icons.delete : Icons.edit_road, color: kRed, onTap: _activeDangerZone.isNotEmpty ? _clearZone : _toggleDrawingMode)], const Divider(color: Colors.white24, indent: 10, endIndent: 10), _HudBtn(icon: Icons.grid_4x4, color: _showGrid ? kGreen : Colors.grey, onTap: () => setState(() => _showGrid = !_showGrid)), _HudBtn(icon: Icons.timeline, color: _showTrails ? kCyan : Colors.grey, onTap: () => setState(() => _showTrails = !_showTrails)), _HudBtn(icon: Icons.threed_rotation, color: _tilt > 0 ? kGreen : Colors.grey, onTap: () => setState(() => _tilt = _tilt > 0 ? 0.0 : 0.6)), _HudBtn(icon: Icons.rotate_left, color: Colors.white, onTap: () { setState(() => _rotation -= 45); _mapController.rotate(_rotation); }), _HudBtn(icon: Icons.rotate_right, color: Colors.white, onTap: () { setState(() => _rotation += 45); _mapController.rotate(_rotation); }), const SizedBox(height: 10)]))),
                    if (_isDrawingMode) Positioned(top: 20, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.orange), borderRadius: BorderRadius.circular(20)), child: const Text("DRAWING MODE: TAP POINTS", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold))))),
                  ],
                ),
              ),
            ],
          ),

          // WAYPOINT PALETTE (BOTTOM)
          if (!_isDrawingMode)
            Positioned(
              bottom: 20, left: 0, right: 0,
              child: Center(
                child: _buildGlassPanel(
                  width: 380, // Made wider for delete button
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _WaypointBtn(label: "RALLY", icon: Icons.flag, color: Colors.blueAccent, isSelected: _placingWaypointType == "RALLY", onTap: () => setState(() => _placingWaypointType = "RALLY")),
                        _WaypointBtn(label: "ENEMY", icon: Icons.warning, color: kRed, isSelected: _placingWaypointType == "ENEMY", onTap: () => setState(() => _placingWaypointType = "ENEMY")),
                        _WaypointBtn(label: "MEDIC", icon: Icons.local_hospital, color: Colors.white, isSelected: _placingWaypointType == "MED", onTap: () => setState(() => _placingWaypointType = "MED")),
                        _WaypointBtn(label: "LZ", icon: Icons.flight_land, color: kGreen, isSelected: _placingWaypointType == "LZ", onTap: () => setState(() => _placingWaypointType = "LZ")),
                        const SizedBox(width: 10),
                        // DELETE WAYPOINT BUTTON
                        _WaypointBtn(label: "DELETE", icon: Icons.delete_forever, color: Colors.orange, isSelected: _isDeleteWaypointMode, onTap: () => setState(() { _isDeleteWaypointMode = !_isDeleteWaypointMode; _placingWaypointType = null; })),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (_placingWaypointType != null) Positioned(top: 80, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.yellowAccent), borderRadius: BorderRadius.circular(20)), child: Text("TAP MAP TO PLACE $_placingWaypointType", style: const TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold))))),
          if (_isDeleteWaypointMode) Positioned(top: 80, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: Colors.black87, border: Border.all(color: Colors.red), borderRadius: BorderRadius.circular(20)), child: const Text("DELETE MODE: TAP MARKER TO REMOVE", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))))),
        ],
      ),
    );
  }

  List<LatLng> _createVisionCone(LatLng center, double heading) {
    double radius = 0.0005;
    double angleRad = heading * (math.pi / 180);
    double coneWidth = 45 * (math.pi / 180);
    return [center, LatLng(center.latitude + radius * math.cos(angleRad - coneWidth/2), center.longitude + radius * math.sin(angleRad - coneWidth/2)), LatLng(center.latitude + radius * math.cos(angleRad), center.longitude + radius * math.sin(angleRad)), LatLng(center.latitude + radius * math.cos(angleRad + coneWidth/2), center.longitude + radius * math.sin(angleRad + coneWidth/2)), center];
  }
}

class _HudBtn extends StatelessWidget {
  final IconData icon; final Color color; final VoidCallback onTap;
  const _HudBtn({required this.icon, required this.color, required this.onTap});
  @override Widget build(BuildContext context) => IconButton(icon: Icon(icon, color: color, size: 20), onPressed: onTap);
}

class _WaypointBtn extends StatelessWidget {
  final String label; final IconData icon; final Color color; final bool isSelected; final VoidCallback onTap;
  const _WaypointBtn({required this.label, required this.icon, required this.color, required this.isSelected, required this.onTap});
  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: isSelected ? color.withOpacity(0.5) : Colors.black26, shape: BoxShape.circle, border: Border.all(color: color)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold))
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
    final paint = Paint()..color = kGreen.withOpacity(0.05)..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 100) canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (double y = 0; y < size.height; y += 100) canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}