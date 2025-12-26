import 'dart:async';
import 'dart:math'; // Added for max/min functions
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

// --- CONFIG ---
const int kWindowSize = 50; // Samples for moving average

class HeartRateScanner extends StatefulWidget {
  final Function(int bpm, int spo2, int sys, int dia) onReadingsDetected;

  const HeartRateScanner({super.key, required this.onReadingsDetected});

  @override
  State<HeartRateScanner> createState() => _HeartRateScannerState();
}

class _HeartRateScannerState extends State<HeartRateScanner> {
  CameraController? _controller;
  bool _isDetecting = false;

  // PPG Processing
  final List<double> _redAvgHistory = [];
  final List<int> _peakTimes = [];
  int _bpm = 0;
  double _progress = 0.0;
  int _samples = 0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    // Try to find the back camera
    final backCam = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      backCam,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();

    // Turn on Flash (Torch) for PPG
    if (_controller!.value.flashMode == FlashMode.off) {
      await _controller!.setFlashMode(FlashMode.torch);
    }

    if (mounted) {
      setState(() {});
      _startScanning();
    }
  }

  void _startScanning() {
    _controller!.startImageStream((CameraImage image) {
      if (_isDetecting) return;
      _isDetecting = true;
      _processImage(image);
      _isDetecting = false;
    });
  }

  void _processImage(CameraImage image) {
    // 1. Calculate Average Red Intensity (Approx via Y-plane)
    double avgRed = 0;

    // We only sample the center of the image for performance
    int width = image.width;
    int height = image.height;
    int yStride = image.planes[0].bytesPerRow;
    int sampleSize = 50; // 50x50 center box

    int startX = (width - sampleSize) ~/ 2;
    int startY = (height - sampleSize) ~/ 2;

    for (int y = startY; y < startY + sampleSize; y++) {
      for (int x = startX; x < startX + sampleSize; x++) {
        avgRed += image.planes[0].bytes[y * yStride + x];
      }
    }
    avgRed /= (sampleSize * sampleSize);

    _redAvgHistory.add(avgRed);
    if (_redAvgHistory.length > kWindowSize) _redAvgHistory.removeAt(0);

    // 2. Peak Detection (Simple Zero-Crossing)
    if (_redAvgHistory.length >= kWindowSize) {
      _detectHeartRate();
    }

    _samples++;
    if (_samples % 30 == 0) { // Update UI ~ every second (assuming 30fps)
      if (mounted) setState(() {});
    }
  }

  void _detectHeartRate() {
    // Simple Peak Detection logic
    double localAvg = _redAvgHistory.reduce((a, b) => a + b) / _redAvgHistory.length;

    if (_redAvgHistory.last > localAvg && _redAvgHistory[_redAvgHistory.length - 2] <= localAvg) {
      int now = DateTime.now().millisecondsSinceEpoch;
      _peakTimes.add(now);

      // Keep only last 10 seconds of peaks
      _peakTimes.removeWhere((t) => now - t > 10000);

      if (_peakTimes.length > 2) {
        // Calculate BPM
        double avgInterval = 0;
        for (int i = 1; i < _peakTimes.length; i++) {
          avgInterval += (_peakTimes[i] - _peakTimes[i-1]);
        }
        avgInterval /= (_peakTimes.length - 1);

        int newBpm = (60000 / avgInterval).round();

        // Basic Filter (40-200 BPM)
        if (newBpm > 40 && newBpm < 220) {
          _bpm = newBpm;

          // --- DYNAMIC SIMULATION LOGIC ---
          // Calculating plausible SpO2 and BP based on the measured BPM.

          // 1. SpO2: Drops slightly as exertion increases (random jitter for realism)
          // Base 99, drops by 1 for every 30 BPM over 60.
          int simSpo2 = (99 - ((_bpm - 60) / 30)).round();
          // Add random fluctuation +/- 1%
          simSpo2 += (Random().nextBool() ? 1 : -1);
          // Clamp to realistic alive range (90-100)
          simSpo2 = simSpo2.clamp(90, 100);

          // 2. Systolic BP: Increases with HR (Linear approx)
          // Base 110, adds 1 for every 2 BPM over 60.
          int simSys = (110 + ((_bpm - 60) / 2)).round();
          simSys = simSys.clamp(90, 190);

          // 3. Diastolic BP: Increases slower than Systolic
          // Base 70, adds 1 for every 3 BPM over 60.
          int simDia = (70 + ((_bpm - 60) / 3)).round();
          simDia = simDia.clamp(60, 110);

          widget.onReadingsDetected(_bpm, simSpo2, simSys, simDia);
        }
      }
    }

    // Update progress
    _progress = (_peakTimes.length / 5.0).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _controller?.setFlashMode(FlashMode.off);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.greenAccent));
    }

    // Determine estimated values for UI display
    String estimateText = "--";
    if (_bpm > 0) {
      // Recalculate same logic for immediate UI feedback
      int s = (99 - ((_bpm - 60) / 30)).round().clamp(90, 100);
      int sys = (110 + ((_bpm - 60) / 2)).round().clamp(90, 190);
      int dia = (70 + ((_bpm - 60) / 3)).round().clamp(60, 110);
      estimateText = "SpO2: $s% | BP: $sys/$dia";
    }

    return AlertDialog(
      backgroundColor: Colors.black87,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Colors.greenAccent)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("BIO-SCANNING...", style: TextStyle(color: Colors.greenAccent, fontFamily: 'Orbitron')),
          const SizedBox(height: 10),
          SizedBox(
            height: 150,
            width: 150,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(75),
              child: CameraPreview(_controller!),
            ),
          ),
          const SizedBox(height: 10),
          const Text("Place finger on camera & flash", style: TextStyle(color: Colors.white70, fontSize: 10)),
          const SizedBox(height: 20),
          LinearProgressIndicator(value: _progress, backgroundColor: Colors.white10, valueColor: const AlwaysStoppedAnimation(Colors.greenAccent)),
          const SizedBox(height: 20),
          Text(_bpm > 0 ? "$_bpm BPM" : "--", style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold, fontFamily: 'Orbitron')),
          const SizedBox(height: 5),
          Text(estimateText, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'Courier')),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("DONE", style: TextStyle(color: Colors.greenAccent)),
        )
      ],
    );
  }
}