import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class VoiceComms {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  
  String? _currentRecordingPath;
  bool _isRecording = false;

  bool get isRecording => _isRecording;

  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  Future<void> startRecording() async {
    try {
      if (await hasPermission()) {
        final dir = await getTemporaryDirectory();
        _currentRecordingPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        
        // Config: AAC Low Complexity for reasonable size/quality balance
        const config = RecordConfig(encoder: AudioEncoder.aacLc);
        
        await _recorder.start(config, path: _currentRecordingPath!);
        _isRecording = true;
        debugPrint("PTT: Recording started at $_currentRecordingPath");
      }
    } catch (e) {
      debugPrint("PTT Error: $e");
    }
  }

  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    try {
      final path = await _recorder.stop();
      _isRecording = false;
      debugPrint("PTT: Stopped at $path");
      return path;
    } catch (e) {
      debugPrint("PTT Stop Error: $e");
      _isRecording = false;
      return null;
    }
  }

  Future<void> playAudio(List<int> bytes) async {
    try {
      // Must write to file to play with SourceUrl (or use SourceBytes if supported)
      // SourceBytes is cleaner but sometimes picky on formats. Let's try SourceBytes first.
      // Actually, audioplayers 6.0 supports SourceBytes via BytesSource
      
      await _player.play(BytesSource(Uint8List.fromList(bytes)));
      debugPrint("PTT: Playing audio (${bytes.length} bytes)");
    } catch (e) {
      debugPrint("PTT Playback Error: $e");
    }
  }

  void dispose() {
    _recorder.dispose();
    _player.dispose();
  }
}
