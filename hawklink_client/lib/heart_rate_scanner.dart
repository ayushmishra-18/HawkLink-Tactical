import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'sci_fi_ui.dart';

class HeartRateScanner extends StatefulWidget {
  // Updated callback to return all 3 metrics
  final Function(int bpm, int spo2, int systolic, int diastolic) onReadingsDetected;
  const HeartRateScanner({super.key, required this.onReadingsDetected});

  @override
  State<HeartRateScanner> createState() => _HeartRateScannerState();
}

class _HeartRateScannerState extends State<HeartRateScanner> {
  CameraController? _controller;
  bool _isScanning = false;
  String _status = "INITIALIZING SENSORS...";

  // PPG Processing Variables
  final List<double> _redHistory = [];
  final int _windowSize = 150;
  DateTime? _startTime;
  int _beatCount = 0;

  // Live Readings
  int _currentBpm = 0;
  int _currentSpO2 = 0;
  int _currentSys = 0;
  int _currentDia = 0;

  // Animation
  double _graphHeight = 50.0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (await Permission.camera.request().isDenied) {
      setState(() => _status = "CAMERA ACCESS DENIED");
      return;
    }

    try {
      final cameras = await availableCameras();
      final firstCamera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        firstCamera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();
      await _controller!.setFlashMode(FlashMode.torch);
      _controller!.startImageStream(_processImage);

      setState(() {
        _isScanning = true;
        _status = "PLACE FINGER ON CAMERA";
      });

    } catch (e) {
      setState(() => _status = "SENSOR ERROR: $e");
    }
  }

  void _processImage(CameraImage image) {
    if (!_isScanning) return;

    // 1. Calculate Average Red Intensity (Luminance approximation)
    double avgRed = 0;
    int count = 0;
    int width = image.width;
    int height = image.height;
    int centerX = width ~/ 2;
    int centerY = height ~/ 2;
    int sampleBox = 20;

    for (int y = centerY - sampleBox; y < centerY + sampleBox; y++) {
      for (int x = centerX - sampleBox; x < centerX + sampleBox; x++) {
        if (y >= 0 && y < height && x >= 0 && x < width) {
          avgRed += image.planes[0].bytes[y * width + x];
          count++;
        }
      }
    }
    avgRed /= count;

    _updateMetrics(avgRed);
  }

  void _updateMetrics(double val) {
    _redHistory.add(val);
    if (_redHistory.length > _windowSize) _redHistory.removeAt(0);

    // Visualizer Logic
    if (_redHistory.length > 20) {
      double localAvg = _redHistory.sublist(_redHistory.length - 10).reduce((a, b) => a + b) / 10;
      double previousAvg = _redHistory.sublist(_redHistory.length - 20, _redHistory.length - 10).reduce((a, b) => a + b) / 10;

      if (mounted) {
        setState(() {
          _graphHeight = 30 + ((val - localAvg).abs() * 5).clamp(0.0, 50.0);
        });
      }

      // Check if finger is placed (Brightness check)
      if (val < 50) {
        if (mounted && _status != "PLACE FINGER ON CAMERA") {
          setState(() => _status = "PLACE FINGER ON CAMERA");
        }
        return;
      }

      if (mounted && _status != "ANALYZING...") {
        setState(() => _status = "ANALYZING...");
      }

      // Beat Detection
      if (val > localAvg + 2 && val > previousAvg) {
        DateTime now = DateTime.now();
        if (_startTime == null) {
          _startTime = now;
          _beatCount = 0;
        } else {
          if (now.difference(_startTime!).inMilliseconds > 300) { // Debounce
            _beatCount++;

            // Calculate every 5 beats
            Duration diff = now.difference(_startTime!);
            if (diff.inSeconds >= 4) {
              double seconds = diff.inMilliseconds / 1000.0;
              int bpm = ((_beatCount / seconds) * 60).toInt();

              if (bpm > 50 && bpm < 180) {
                // --- BIOMETRIC CALCULATIONS (Simulated based on BPM) ---
                // SpO2: Generally stable, drops slightly with high exertion
                int spo2 = 96 + Random().nextInt(4);

                // BP: Heuristic approximation (Not medical grade)
                // Systolic rises with HR, Diastolic is more stable
                int sys = 110 + ((bpm - 60) ~/ 2) + Random().nextInt(10);
                int dia = 70 + ((bpm - 60) ~/ 4) + Random().nextInt(5);

                if(mounted) {
                  setState(() {
                    _currentBpm = bpm;
                    _currentSpO2 = spo2;
                    _currentSys = sys;
                    _currentDia = dia;
                    _status = "VITALS CAPTURED";
                  });
                }

                // Send data back
                widget.onReadingsDetected(_currentBpm, _currentSpO2, _currentSys, _currentDia);
              }

              _startTime = now;
              _beatCount = 0;
            }
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _controller?.setFlashMode(FlashMode.off);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SciFiPanel(
        showBg: true,
        borderColor: kSciFiRed,
        title: "BIOMETRIC SCAN",
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Camera Preview
            Container(
              height: 120, width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: kSciFiRed.withOpacity(0.5)),
                color: Colors.black,
              ),
              child: ClipRect(
                child: _controller != null && _controller!.value.isInitialized
                    ? CameraPreview(_controller!)
                    : const Center(child: CircularProgressIndicator(color: kSciFiRed)),
              ),
            ),

            // Graph
            Container(
              height: 40, width: double.infinity,
              color: Colors.black54,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  height: _graphHeight, width: 200,
                  decoration: BoxDecoration(color: kSciFiRed, boxShadow: [BoxShadow(color: kSciFiRed, blurRadius: 10)]),
                ),
              ),
            ),

            const SizedBox(height: 10),
            Text(_status, style: const TextStyle(color: Colors.white, fontFamily: 'Courier', fontSize: 10)),
            const SizedBox(height: 10),

            // Metrics Grid
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _MetricBox("BPM", "$_currentBpm", kSciFiRed),
                _MetricBox("SpO2", "$_currentSpO2%", kSciFiCyan),
                _MetricBox("BP", "$_currentSys/$_currentDia", kSciFiGreen),
              ],
            ),

            const SizedBox(height: 15),
            SciFiButton(label: "CLOSE", icon: Icons.check, color: Colors.white, onTap: () => Navigator.pop(context))
          ],
        ),
      ),
    );
  }

  Widget _MetricBox(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: Colors.grey, fontSize: 8)),
        Text(value, style: TextStyle(color: color, fontFamily: 'Orbitron', fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }
}