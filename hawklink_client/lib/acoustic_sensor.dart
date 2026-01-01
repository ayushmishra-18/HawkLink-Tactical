import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';

class AcousticSensor {
  final Function() onGunshotDetected;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  NoiseMeter? _noiseMeter;
  bool _isListening = false;
  Timer? _retryTimer;

  // Threshold: 80.0 dB for testing.
  // Real gunshot is >120 dB, but phone mics clip around 90-100 dB.
  static const double kGunshotThreshold = 80.0;

  DateTime _lastTrigger = DateTime.now();

  AcousticSensor({required this.onGunshotDetected});

  Future<void> start() async {
    if (_isListening) return;

    // 1. Explicit Permission Check
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        debugPrint("MIC PERMISSION DENIED: Cannot start acoustic sensor.");
        return;
      }
    }

    // Small delay to allow OS audio system to settle after permission grant
    await Future.delayed(const Duration(milliseconds: 500));

    _initStream();
  }

  void _initStream() {
    try {
      // Clear previous instance if any
      _noiseMeter = null;
      _noiseMeter = NoiseMeter();

      // 3. Listen to Stream
      _noiseSubscription = _noiseMeter?.noise.listen(
            (NoiseReading reading) {
          _analyzeNoise(reading);
        },
        onError: (err) {
          debugPrint("Mic Error: $err");
          _handleStreamError();
        },
        onDone: () {
          debugPrint("Mic Stream Closed Unexpectedly");
          _handleStreamError();
        },
        cancelOnError: false, // Keep trying if possible
      );

      _isListening = true;
      debugPrint("Acoustic Sensor Started (Threshold: ${kGunshotThreshold}dB)");

    } catch (e) {
      debugPrint("Noise Meter Init Error: $e");
      _handleStreamError();
    }
  }

  void _handleStreamError() {
    _isListening = false;
    _noiseSubscription?.cancel();

    // Auto-retry logic
    if (_retryTimer?.isActive ?? false) return;

    debugPrint("Acoustic Sensor: Attempting restart in 2 seconds...");
    _retryTimer = Timer(const Duration(seconds: 2), () {
      debugPrint("Acoustic Sensor: Retrying...");
      start();
    });
  }

  void _analyzeNoise(NoiseReading reading) {
    // Uncomment to debug live levels
    // debugPrint("dB: ${reading.maxDecibel}");

    if (reading.maxDecibel > kGunshotThreshold) {
      // Debounce: Only allow 1 alert every 2 seconds
      if (DateTime.now().difference(_lastTrigger).inSeconds > 2) {
        _lastTrigger = DateTime.now();
        debugPrint("!!! GUNSHOT DETECTED (${reading.maxDecibel.toStringAsFixed(1)} dB) !!!");
        onGunshotDetected();
      }
    }
  }

  void stop() {
    _retryTimer?.cancel();
    _noiseSubscription?.cancel();
    _noiseMeter = null;
    _isListening = false;
    debugPrint("Acoustic Sensor Stopped.");
  }
}