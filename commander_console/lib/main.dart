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
import 'sci_fi_ui.dart';

// --- CONFIGURATION ---
const int kPort = 4444;
const String kPreSharedKey = 'HAWKLINK_TACTICAL_SECURE_KEY_256';
const String kFixedIV =      'HAWKLINK_IV_16ch';

// --- DATA MODELS ---
class SoldierUnit {
  String id; String role; LatLng location; double heading; int battery; int bpm; String status; DateTime lastSeen; Socket? socket; List<LatLng> pathHistory;
  SoldierUnit({required this.id, this.role="ASSAULT", required this.location, this.heading=0.0, this.battery=100, this.bpm=75, this.status="IDLE", required this.lastSeen, this.socket, List<LatLng>? history}) : pathHistory = history ?? [];
}
class TacticalWaypoint {
  String id; String type; LatLng location; DateTime created;
  TacticalWaypoint({required this.id, required this.type, required this.location, required this.created});
  Map<String, dynamic> toJson() => {'id': id, 'type': type, 'lat': location.latitude, 'lng': location.longitude, 'time': created.toIso8601String()};
}

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
  ServerSocket? _server;
  final List<SoldierUnit> _units = [];
  final List<Map<String, dynamic>> _logs = [];
  final List<TacticalWaypoint> _waypoints = [];
  List<String> _myIps = [];
  final TextEditingController _cmdController = TextEditingController();
  final Map<Socket, List<int>> _clientBuffers = {};
  final AudioPlayer _sfxPlayer = AudioPlayer();
  final AudioPlayer _alertPlayer = AudioPlayer();
  bool _audioEnabled = true;
  final _key = enc.Key.fromUtf8(kPreSharedKey);
  final _iv = enc.IV.fromUtf8(kFixedIV);
  late final _encrypter = enc.Encrypter(enc.AES(_key));
  final MapController _mapController = MapController();
  late AnimationController _pulseController;
  String? _selectedUnitId;
  bool _showGrid = true;
  bool _showTrails = true;
  bool _showRangeRings = true;
  double _tilt = 0.0;
  double _rotation = 0.0;
  bool _isDrawingMode = false;
  String? _placingWaypointType;
  bool _isDeleteWaypointMode = false;
  List<LatLng> _tempDrawPoints = [];
  List<LatLng> _activeDangerZone = [];

  @override void initState() { super.initState(); _startServer(); _getLocalIps(); _loadLogs(); _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(); _sfxPlayer.setReleaseMode(ReleaseMode.stop); _alertPlayer.setReleaseMode(ReleaseMode.stop); }
  @override void dispose() { _sfxPlayer.dispose(); _alertPlayer.dispose(); _pulseController.dispose(); super.dispose(); }

  // --- AUDIO & LOGIC ---
  Future<void> _playSfx(String f) async { if(!_audioEnabled) return; try{ if(_sfxPlayer.state==PlayerState.playing) await _sfxPlayer.stop(); await _sfxPlayer.play(AssetSource('sounds/$f')); }catch(e){_audioEnabled=false;} }
  Future<void> _playAlert(String f) async { if(!_audioEnabled) return; try{ if(_alertPlayer.state==PlayerState.playing) await _alertPlayer.stop(); await _alertPlayer.play(AssetSource('sounds/$f')); }catch(e){} }
  Future<File> _getLogFile() async { final d = await getApplicationDocumentsDirectory(); return File('${d.path}/hawklink_logs.txt'); }
  Future<void> _loadLogs() async { try{ final f=await _getLogFile(); if(await f.exists()){ final c=await f.readAsLines(); setState(() { for(var l in c.reversed.take(100)) _logs.add({'text':l, 'image':null}); }); } }catch(e){} }
  Future<void> _saveLog(String l) async { try{ final f=await _getLogFile(); await f.writeAsString('$l\n', mode: FileMode.append); }catch(e){} }
  Future<String> _saveImageToDisk(String s, String b64) async { try{ final d=await getApplicationDocumentsDirectory(); final i=Directory('${d.path}/HawkLink_Intel'); if(!await i.exists()) await i.create(); String t=DateFormat('yyyyMMdd_HHmmss').format(DateTime.now()); File f=File('${i.path}/IMG_${s}_$t.jpg'); await f.writeAsBytes(base64Decode(b64)); return f.path; }catch(e){return "";} }
  Future<void> _getLocalIps() async { try{ final i=await NetworkInterface.list(type: InternetAddressType.IPv4); setState(()=>_myIps=i.map((x)=>x.addresses.map((y)=>y.address).join(", ")).toList()); }catch(e){} }
  Future<void> _startServer() async { try{ _server=await ServerSocket.bind(InternetAddress.anyIPv4, kPort); _log("SYS", "SERVER ONLINE | PORT $kPort"); _playSfx('connect.mp3'); _server!.listen((c) { _log("NET", "UPLINK ESTABLISHED"); _clientBuffers[c]=[]; c.listen((d)=>_handleData(c,d), onError:(e)=>_removeClient(c), onDone:()=>_removeClient(c)); }); }catch(e){} }
  void _removeClient(Socket c) { setState(() { _units.removeWhere((u)=>u.socket==c); _clientBuffers.remove(c); }); }
  void _handleData(Socket c, List<int> d) { if(!_clientBuffers.containsKey(c)) _clientBuffers[c]=[]; _clientBuffers[c]!.addAll(d); List<int> b=_clientBuffers[c]!; while(true){ int i=b.indexOf(10); if(i==-1) break; List<int> p=b.sublist(0,i); b=b.sublist(i+1); _clientBuffers[c]=b; _processPacket(c,p); } }
  void _processPacket(Socket c, List<int> b) async { try{ final s=utf8.decode(b).trim(); if(s.isEmpty) return; final dec=_encrypter.decrypt64(s, iv:_iv); final j=jsonDecode(dec); if(j['type']=='STATUS') _updateUnit(c,j); else if(j['type']=='CHAT'||j['type']=='ACK'){ _log(j['sender'],j['content']); if(j['content'].contains("SOS")) _playAlert('alert.mp3'); if(j['type']=='ACK') _playSfx('connect.mp3'); } else if(j['type']=='IMAGE'){ String p=await _saveImageToDisk(j['sender'],j['content']); _log(j['sender'], "📸 INTEL RECEIVED", imagePath:p); _playSfx('connect.mp3'); } }catch(e){} }
  void _updateUnit(Socket s, Map<String,dynamic> d) { setState(() { final id=d['id']; final idx=_units.indexWhere((u)=>u.id==id); final loc=LatLng(d['lat'],d['lng']); if(idx!=-1){ _units[idx].location=loc; _units[idx].heading=(d['head']??0.0).toDouble(); _units[idx].role=d['role']??"ASSAULT"; _units[idx].battery=d['bat']; _units[idx].bpm=d['bpm']??75; _units[idx].status=d['state']; _units[idx].lastSeen=DateTime.now(); _units[idx].socket=s; if(_units[idx].pathHistory.isEmpty || const Distance().as(LengthUnit.Meter, _units[idx].pathHistory.last, loc)>5) _units[idx].pathHistory.add(loc); } else { _units.add(SoldierUnit(id:id, location:loc, role:d['role']??"ASSAULT", battery:d['bat'], bpm:d['bpm']??75, status:d['state'], lastSeen:DateTime.now(), socket:s, history:[loc])); _log("NET", "UNIT REGISTERED: $id"); _playSfx('connect.mp3'); } }); }
  void _log(String s, String m, {String? imagePath}) { String t=DateFormat('HH:mm:ss').format(DateTime.now()); String p=m.contains("COPY")?"✅ ":""; String e="$p[$t] $s: $m"; setState(()=>_logs.insert(0, {'text':e, 'image':imagePath})); _saveLog(e); }
  void _broadcastOrder(String t) { if(t.isEmpty) return; String p=_encrypter.encrypt(jsonEncode({'type':'CHAT', 'sender':'COMMAND', 'content':t}), iv:_iv).base64; for(var u in _units) try{u.socket?.add(utf8.encode("$p\n"));}catch(e){} _log("CMD", "BROADCAST: $t"); _cmdController.clear(); _playSfx('order.mp3'); }
  void _issueMoveOrder(LatLng d) { if(_isDrawingMode||_placingWaypointType!=null||_isDeleteWaypointMode||_selectedUnitId==null) return; try{ final u=_units.firstWhere((x)=>x.id==_selectedUnitId); String p=_encrypter.encrypt(jsonEncode({'type':'MOVE_TO', 'sender':'COMMAND', 'content':"MOVE TO ${d.latitude.toStringAsFixed(4)}, ${d.longitude.toStringAsFixed(4)}", 'lat':d.latitude, 'lng':d.longitude}), iv:_iv).base64; u.socket?.add(utf8.encode("$p\n")); _log("CMD", "VECTOR ASSIGNED: $u.id"); _playSfx('order.mp3'); }catch(e){} }
  void _onMapTap(TapPosition p, LatLng l) { if(_isDeleteWaypointMode){ _removeWaypointNear(l); setState(()=>_isDeleteWaypointMode=false); return; } if(_placingWaypointType!=null){ _deployWaypoint(l, _placingWaypointType!); setState(()=>_placingWaypointType=null); return; } if(_isDrawingMode){ setState(()=>_tempDrawPoints.add(l)); return; } setState(()=>_selectedUnitId=null); }
  void _deployWaypoint(LatLng l, String t) { String id="${t}_${DateTime.now().millisecondsSinceEpoch}"; TacticalWaypoint w=TacticalWaypoint(id:id, type:t, location:l, created:DateTime.now()); setState(()=>_waypoints.add(w)); String p=_encrypter.encrypt(jsonEncode({'type':'WAYPOINT', 'action':'ADD', 'data':w.toJson()}), iv:_iv).base64; for(var u in _units) try{u.socket?.add(utf8.encode("$p\n"));}catch(e){} _log("CMD", "WAYPOINT DEPLOYED: $t"); _playSfx('order.mp3'); }

  // --- FIXED DELETE LOGIC ---
  void _removeWaypointNear(LatLng point) {
    try {
      TacticalWaypoint? closestWp;
      double minDistance = double.infinity;
      const double threshold = 500.0; // Meters

      final distanceCalc = const Distance();

      // Find the closest marker, not just the first one
      for (var wp in _waypoints) {
        final double dist = distanceCalc.as(LengthUnit.Meter, wp.location, point);
        if (dist < threshold) {
          if (dist < minDistance) {
            minDistance = dist;
            closestWp = wp;
          }
        }
      }

      if (closestWp != null) {
        setState(() => _waypoints.remove(closestWp));

        final packet = _encryptPacket({'type': 'WAYPOINT', 'action': 'REMOVE', 'id': closestWp!.id});
        final delimitedPacket = utf8.encode("$packet\n");
        for (var u in _units) { try { u.socket?.add(delimitedPacket); } catch (e) {} }

        _log("CMD", "WAYPOINT REMOVED: ${closestWp.type}");
        _playSfx('connect.mp3');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("NO WAYPOINT NEARBY")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ERROR REMOVING WAYPOINT")));
    }
  }

  void _toggleDrawingMode() { setState(() { _isDrawingMode=!_isDrawingMode; _tempDrawPoints=[]; }); }
  void _deployCustomZone() { if(_tempDrawPoints.length<3) return; setState(() { _activeDangerZone=List.from(_tempDrawPoints); _isDrawingMode=false; _tempDrawPoints=[]; }); List<List<double>> pts=_activeDangerZone.map((p)=>[p.latitude, p.longitude]).toList(); String p=_encrypter.encrypt(jsonEncode({'type':'ZONE', 'sender':'COMMAND', 'points':pts}), iv:_iv).base64; for(var u in _units) try{u.socket?.add(utf8.encode("$p\n"));}catch(e){} _log("CMD", "ZONE DEPLOYED"); _playAlert('alert.mp3'); }
  void _clearZone() { setState(() { _activeDangerZone=[]; _tempDrawPoints=[]; }); String p=_encrypter.encrypt(jsonEncode({'type':'ZONE', 'sender':'COMMAND', 'points':[]}), iv:_iv).base64; for(var u in _units) try{u.socket?.add(utf8.encode("$p\n"));}catch(e){} _log("CMD", "ZONE CLEARED"); }
  String _encryptPacket(Map<String, dynamic> d) => _encrypter.encrypt(jsonEncode(d), iv:_iv).base64;
  IconData _getRoleIcon(String r) { switch(r){ case "MEDIC": return Icons.medical_services; case "SCOUT": return Icons.visibility; case "SNIPER": return Icons.gps_fixed; case "ENGINEER": return Icons.build; default: return Icons.shield; } }
  List<LatLng> _createVisionCone(LatLng c, double h) { double r=0.0005; double a=h*(math.pi/180); double w=45*(math.pi/180); return [c, LatLng(c.latitude+r*math.cos(a-w/2), c.longitude+r*math.sin(a-w/2)), LatLng(c.latitude+r*math.cos(a), c.longitude+r*math.sin(a)), LatLng(c.latitude+r*math.cos(a+w/2), c.longitude+r*math.sin(a+w/2)), c]; }
  void _showImagePreview(String path) { showDialog(context: context, builder: (ctx) => Dialog(backgroundColor: Colors.transparent, child: Stack(alignment: Alignment.center, children: [Image.file(File(path)), Positioned(top: 10, right: 10, child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 30), onPressed: () => Navigator.pop(ctx)))]))); }

  // --- ICON HELPER ---
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
                    Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("IP: ${_myIps.isNotEmpty ? _myIps.first : '...'}", style: const TextStyle(color: kSciFiGreen, fontSize: 10, fontFamily: 'Courier New')), const Text("SECURE: AES-256", style: TextStyle(color: kSciFiCyan, fontSize: 10, fontFamily: 'Courier New'))])),
                    Expanded(
                      flex: 3,
                      child: ListView.builder(
                        itemCount: _units.length,
                        itemBuilder: (ctx, i) {
                          final u = _units[i];
                          bool isSelected = u.id == _selectedUnitId;
                          return GestureDetector(
                            onTap: () { setState(() => _selectedUnitId = u.id); _mapController.move(u.location, 17); },
                            child: SciFiPanel(
                              borderColor: u.status=="SOS" ? kSciFiRed : (isSelected ? kSciFiCyan : kSciFiGreen.withOpacity(0.5)),
                              title: "UNIT ${u.id}",
                              child: Row(children: [Icon(_getRoleIcon(u.role), color: u.status=="SOS" ? kSciFiRed : kSciFiGreen), const SizedBox(width: 10), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(u.role, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Orbitron')), Text("BAT: ${u.battery}% | BPM: ${u.bpm}", style: const TextStyle(color: Colors.grey, fontSize: 10))]), const Spacer(), if(u.status=="SOS") const BlinkingText("SOS", color: kSciFiRed)]),
                            ),
                          );
                        },
                      ),
                    ),
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
                                  return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(l['text'], style: const TextStyle(color: kSciFiGreen, fontSize: 9, fontFamily: 'Courier New')), if(l['image']!=null) GestureDetector(onTap: ()=>_showImagePreview(l['image']), child: Container(margin: const EdgeInsets.only(top: 4), height: 60, width: 100, decoration: BoxDecoration(border: Border.all(color: kSciFiCyan)), child: Image.file(File(l['image']), fit: BoxFit.cover)))]));
                                }
                            )
                        )
                    ),
                    Padding(padding: const EdgeInsets.all(8.0), child: TextField(controller: _cmdController, style: const TextStyle(color: kSciFiCyan, fontFamily: 'Courier New'), decoration: const InputDecoration(hintText: "ENTER COMMAND...", hintStyle: TextStyle(color: Colors.grey), filled: true, fillColor: kSciFiDarkBlue, border: OutlineInputBorder(borderSide: BorderSide(color: kSciFiCyan)), isDense: true), onSubmitted: _broadcastOrder)),
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
                          if (_activeDangerZone.isNotEmpty) PolygonLayer(polygons: [Polygon(points: _activeDangerZone, color: kSciFiRed.withOpacity(0.2), borderColor: kSciFiRed, borderStrokeWidth: 2, isFilled: true)]),
                          if (_isDrawingMode && _tempDrawPoints.isNotEmpty) ...[PolylineLayer(polylines: [Polyline(points: _tempDrawPoints, color: Colors.orange, strokeWidth: 2, isDotted: true)]), MarkerLayer(markers: _tempDrawPoints.map((p) => Marker(point: p, width: 10, height: 10, child: Container(decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle)))).toList())],
                          if (_showGrid) IgnorePointer(child: CustomPaint(size: Size.infinite, painter: TacticalGridPainter())),
                          if (_showTrails) PolylineLayer(polylines: _units.map((u) => Polyline(points: u.pathHistory, strokeWidth: 2.0, color: u.status=="SOS" ? kSciFiRed : kSciFiGreen, isDotted: true)).toList()),
                          PolygonLayer(polygons: _units.map((u) => Polygon(points: _createVisionCone(u.location, u.heading), color: kSciFiCyan.withOpacity(0.15), isFilled: true, borderStrokeWidth: 0)).toList()),
                          if (_selectedUnitId != null && _showRangeRings) CircleLayer(circles: [CircleMarker(point: _units.firstWhere((u) => u.id == _selectedUnitId).location, radius: 50, color: Colors.transparent, borderColor: kSciFiCyan.withOpacity(0.5), borderStrokeWidth: 1, useRadiusInMeter: true)]),

                          // --- MARKER LAYER FOR WAYPOINTS (FIXED) ---
                          MarkerLayer(
                              markers: _waypoints.map((wp) => Marker(
                                  point: wp.location,
                                  width: 50,
                                  height: 50,
                                  child: Column(
                                      children: [
                                        Icon(_getWaypointIcon(wp.type), color: _getWaypointColor(wp.type), size: 30),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4),
                                          color: Colors.black54,
                                          child: Text(wp.type, style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold)),
                                        )
                                      ]
                                  )
                              )).toList()
                          ),

                          MarkerLayer(markers: _units.map((u) { bool isSelected = u.id == _selectedUnitId; return Marker(point: u.location, width: 80, height: 80, child: Transform.rotate(angle: -_rotation * (math.pi / 180), child: Stack(alignment: Alignment.center, children: [if(u.status=="SOS") ScaleTransition(scale: _pulseController, child: Container(width: 60, height: 60, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kSciFiRed, width: 2)))), if(isSelected) RotationTransition(turns: _pulseController, child: Container(width: 50, height: 50, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kSciFiCyan, width: 2, style: BorderStyle.solid)))), Column(mainAxisSize: MainAxisSize.min, children: [Text(u.id, style: TextStyle(color: isSelected ? kSciFiCyan : Colors.white, fontSize: 8, fontWeight: FontWeight.bold, backgroundColor: Colors.black54)), Transform.rotate(angle: (u.heading * (math.pi / 180)), child: Icon(_getRoleIcon(u.role), color: u.status=="SOS" ? kSciFiRed : kSciFiCyan, size: 24))])]))); }).toList()),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 20, right: 20,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height - 150,
                          maxWidth: 100,
                        ),
                        child: SciFiPanel(
                          showBg: true,
                          width: 100,
                          child: SingleChildScrollView(
                            child: Column(children: [
                              const SizedBox(height: 10),
                              if (_isDrawingMode) ...[
                                SciFiButton(label: "OK", icon: Icons.check, color: kSciFiGreen, onTap: _deployCustomZone),
                                const SizedBox(height: 8),
                                SciFiButton(label: "X", icon: Icons.close, color: kSciFiRed, onTap: _toggleDrawingMode)
                              ] else ...[
                                SciFiButton(label: "Z", icon: _activeDangerZone.isNotEmpty ? Icons.delete : Icons.edit_road, color: kSciFiRed, onTap: _activeDangerZone.isNotEmpty ? _clearZone : _toggleDrawingMode)
                              ],
                              const Divider(color: Colors.white24, indent: 10, endIndent: 10),
                              SciFiButton(label: "G", icon: Icons.grid_4x4, color: _showGrid ? kSciFiGreen : Colors.grey, onTap: () => setState(() => _showGrid = !_showGrid)),
                              const SizedBox(height: 8),
                              SciFiButton(label: "R", icon: Icons.radar, color: _showRangeRings ? kSciFiCyan : Colors.grey, onTap: () => setState(() => _showRangeRings = !_showRangeRings)),
                              const SizedBox(height: 8),
                              SciFiButton(label: "T", icon: Icons.timeline, color: _showTrails ? kSciFiCyan : Colors.grey, onTap: () => setState(() => _showTrails = !_showTrails)),
                              const SizedBox(height: 8),
                              SciFiButton(label: "3D", icon: Icons.threed_rotation, color: _tilt > 0 ? kSciFiGreen : Colors.grey, onTap: () => setState(() => _tilt = _tilt > 0 ? 0.0 : 0.6)),
                              const SizedBox(height: 8),
                              SciFiButton(label: "<", icon: Icons.rotate_left, color: Colors.white, onTap: () { setState(() => _rotation -= 45); _mapController.rotate(_rotation); }),
                              const SizedBox(height: 8),
                              SciFiButton(label: ">", icon: Icons.rotate_right, color: Colors.white, onTap: () { setState(() => _rotation += 45); _mapController.rotate(_rotation); }),
                              const SizedBox(height: 10)
                            ]),
                          ),
                        ),
                      ),
                    ),
                    if (!_isDrawingMode)
                      Positioned(
                          bottom: 30, left: 20, right: 20,
                          child: Center(
                            child: SciFiPanel(
                              showBg: true,
                              borderColor: kSciFiGreen.withOpacity(0.5),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SciFiButton(label: "RALLY", icon: Icons.flag, color: Colors.blue, onTap: () => setState(() => _placingWaypointType = "RALLY")),
                                      const SizedBox(width: 8),
                                      SciFiButton(label: "ENEMY", icon: Icons.warning, color: kSciFiRed, onTap: () => setState(() => _placingWaypointType = "ENEMY")),
                                      const SizedBox(width: 8),
                                      SciFiButton(label: "MED", icon: Icons.medical_services, color: Colors.white, onTap: () => setState(() => _placingWaypointType = "MED")),
                                      const SizedBox(width: 8),
                                      SciFiButton(label: "LZ", icon: Icons.flight_land, color: kSciFiGreen, onTap: () => setState(() => _placingWaypointType = "LZ")),
                                      const SizedBox(width: 20),
                                      SciFiButton(label: "DEL", icon: Icons.delete, color: Colors.orange, onTap: () => setState(() => _isDeleteWaypointMode = !_isDeleteWaypointMode))
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          )
                      ),
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