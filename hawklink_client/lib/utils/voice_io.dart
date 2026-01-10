import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

class VoiceIO {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _currentRecordingPath;
  bool _isRecording = false;

  Future<void> init() async {
    // Check permissions if needed, though permission_handler handles this usually
    await _player.setReleaseMode(ReleaseMode.stop);
  }

  Future<void> startRecording() async {
    try {
      if (await _recorder.hasPermission()) {
        final dir = await getTemporaryDirectory();
        _currentRecordingPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        
        // Config: AAC Low Overhead
        const config = RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000); // 64kbps mono sufficient for voice
        
        await _recorder.start(config, path: _currentRecordingPath!);
        _isRecording = true;
        debugPrint("VOICE TX: Started recording to $_currentRecordingPath");
      }
    } catch (e) {
      debugPrint("VOICE TX Error: $e");
    }
  }

  Future<File?> stopRecording() async {
    if (!_isRecording) return null;
    try {
      final path = await _recorder.stop();
      _isRecording = false;
      if (path != null) {
        debugPrint("VOICE TX: Stopped recording. File saved at $path");
        return File(path);
      }
    } catch (e) {
      debugPrint("VOICE TX Stop Error: $e");
    }
    return null;
  }

  Future<void> playAudio(List<int> bytes) async {
    try {
      final source = BytesSource(Uint8List.fromList(bytes));
      await _player.play(source);
      debugPrint("VOICE RX: Playing ${bytes.length} bytes");
    } catch (e) {
      debugPrint("VOICE RX Error: $e");
    }
  }

  void dispose() {
    _recorder.dispose();
    _player.dispose();
  }
}
