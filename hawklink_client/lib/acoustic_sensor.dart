import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';

class AcousticSensor {
  final Function() onGunshotDetected;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  NoiseMeter? _noiseMeter;
  bool _isListening = false;

  // Threshold: 85.0 dB for easier testing (Simulated Gunshot/Clap)
  // In a real scenario, this would be closer to 110-120 dB
  static const double kGunshotThreshold = 85.0;

  DateTime _lastTrigger = DateTime.now();

  AcousticSensor({required this.onGunshotDetected});

  Future<void> start() async {
    if (_isListening) return;

    if (await Permission.microphone.request().isGranted) {
      try {
        _noiseMeter = NoiseMeter();
        _noiseSubscription = _noiseMeter?.noise.listen(
              (NoiseReading reading) {
            _analyzeNoise(reading);
          },
          onError: (err) => debugPrint("Mic Error: $err"),
        );
        _isListening = true;
        debugPrint("Acoustic Sensor Started.");
      } catch (e) {
        debugPrint("Noise Meter Init Error: $e");
      }
    } else {
      debugPrint("Microphone permission denied.");
    }
  }

  void _analyzeNoise(NoiseReading reading) {
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
    _noiseSubscription?.cancel();
    _isListening = false;
  }
}