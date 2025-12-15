import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'sci_fi_ui.dart';

class HeartRateScanner extends StatefulWidget {
  final Function(int) onBpmDetected;
  const HeartRateScanner({super.key, required this.onBpmDetected});

  @override
  State<HeartRateScanner> createState() => _HeartRateScannerState();
}

class _HeartRateScannerState extends State<HeartRateScanner> {
  CameraController? _controller;
  bool _isScanning = false;
  String _status = "INITIALIZING SENSORS...";

  // PPG Processing Variables
  final List<double> _redHistory = [];
  final int _windowSize = 150; // Buffer size for analysis
  DateTime? _startTime;
  int _beatCount = 0;
  int _currentBpm = 0;

  // Animation
  double _graphHeight = 50.0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    // 1. Request Permission
    if (await Permission.camera.request().isDenied) {
      setState(() => _status = "CAMERA ACCESS DENIED");
      return;
    }

    try {
      // 2. Find back camera
      final cameras = await availableCameras();
      final firstCamera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // 3. Setup Controller (Low Resolution is faster for processing)
      _controller = CameraController(
        firstCamera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();

      // 4. Turn on Flash (Torch) to illuminate finger
      await _controller!.setFlashMode(FlashMode.torch);

      // 5. Start Image Stream
      _controller!.startImageStream(_processImage);

      setState(() {
        _isScanning = true;
        _status = "PLACE FINGER ON CAMERA";
      });

    } catch (e) {
      setState(() => _status = "SENSOR ERROR: $e");
    }
  }

  // --- THE ALGORITHM ---
  void _processImage(CameraImage image) {
    if (!_isScanning) return;

    // 1. Calculate Average Red Intensity
    // YUV420 format: Y plane is luminance (brightness/greyscale)
    // We approximate "Redness" changes by monitoring luminance changes when flash is on/red finger covers lens.
    // A simplified approach for performance: Average the center pixels of the Y-plane.

    double avgRed = 0;
    int count = 0;

    // Sample center 50x50 pixels
    int width = image.width;
    int height = image.height;
    int centerX = width ~/ 2;
    int centerY = height ~/ 2;
    int sampleBox = 20;

    for (int y = centerY - sampleBox; y < centerY + sampleBox; y++) {
      for (int x = centerX - sampleBox; x < centerX + sampleBox; x++) {
        // Safety check
        if (y >= 0 && y < height && x >= 0 && x < width) {
          avgRed += image.planes[0].bytes[y * width + x];
          count++;
        }
      }
    }
    avgRed /= count;

    // 2. Beat Detection Logic
    _updateBpm(avgRed);
  }

  void _updateBpm(double val) {
    // Add to history buffer
    _redHistory.add(val);
    if (_redHistory.length > _windowSize) _redHistory.removeAt(0);

    // Simple Peak Detection
    if (_redHistory.length > 20) {
      // Calculate local average to detect sudden rise (beat)
      double localAvg = _redHistory.sublist(_redHistory.length - 10).reduce((a, b) => a + b) / 10;
      double previousAvg = _redHistory.sublist(_redHistory.length - 20, _redHistory.length - 10).reduce((a, b) => a + b) / 10;

      // Visualizer Update
      if (mounted) {
        setState(() {
          // Visualize intensity changes
          _graphHeight = 30 + ((val - localAvg).abs() * 5).clamp(0.0, 50.0);
        });
      }

      // Check if finger is actually placed (Low light = no finger)
      if (val < 50) {
        if (mounted && _status != "PLACE FINGER ON CAMERA") {
          setState(() => _status = "PLACE FINGER ON CAMERA");
        }
        return;
      }

      if (mounted && _status != "ANALYZING PULSE...") {
        setState(() => _status = "ANALYZING PULSE...");
      }

      // Detect rising edge (Beat)
      if (val > localAvg + 2 && val > previousAvg) {
        DateTime now = DateTime.now();
        if (_startTime == null) {
          _startTime = now;
          _beatCount = 0;
        } else {
          // Debounce (Human heart can't beat faster than ~250ms)
          if (now.difference(_startTime!).inMilliseconds > 300) {
            _beatCount++;

            // Calculate BPM every 5 beats or 5 seconds
            Duration diff = now.difference(_startTime!);
            if (diff.inSeconds >= 5) {
              double seconds = diff.inMilliseconds / 1000.0;
              int bpm = ((_beatCount / seconds) * 60).toInt();

              // Sanity check (60-160 is realistic range)
              if (bpm > 50 && bpm < 180) {
                _currentBpm = bpm;
                widget.onBpmDetected(_currentBpm);
              }

              // Reset window
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
            Container(
              height: 150, width: double.infinity,
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

            // Real-time Graph
            Container(
              height: 60, width: double.infinity,
              color: Colors.black54,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  height: _graphHeight,
                  width: 200,
                  decoration: BoxDecoration(
                      color: kSciFiRed,
                      boxShadow: [BoxShadow(color: kSciFiRed, blurRadius: 10)]
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),
            Text(_status, style: const TextStyle(color: Colors.white, fontFamily: 'Courier', fontSize: 12)),
            const SizedBox(height: 5),
            Text("BPM: $_currentBpm", style: const TextStyle(color: kSciFiRed, fontFamily: 'Orbitron', fontSize: 30, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),

            SciFiButton(
              label: "CLOSE",
              icon: Icons.close,
              color: Colors.white,
              onTap: () => Navigator.pop(context),
            )
          ],
        ),
      ),
    );
  }
}