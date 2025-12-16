import 'dart:async';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';

class AcousticSensor {
  final Function() onGunshotDetected;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  NoiseMeter? _noiseMeter;
  bool _isListening = false;

  // Threshold in Decibels (Adjusted for demo stability)
  // Was 95.0 -> Now 110.0 (Requires a very loud sound/clap near mic)
  static const double kGunshotThreshold = 110.0;

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
          onError: (err) => print("Mic Error: $err"),
        );
        _isListening = true;
      } catch (e) {
        print("Noise Meter Init Error: $e");
      }
    }
  }

  void _analyzeNoise(NoiseReading reading) {
    // Check max decibel against new threshold
    if (reading.maxDecibel > kGunshotThreshold) {
      // Debounce: Prevent 10 alerts for 1 loud sound.
      // Only allow 1 alert every 2 seconds.
      if (DateTime.now().difference(_lastTrigger).inSeconds > 2) {
        _lastTrigger = DateTime.now();
        onGunshotDetected(); // TRIGGER ALERT
      }
    }
  }

  void stop() {
    _noiseSubscription?.cancel();
    _isListening = false;
  }
}