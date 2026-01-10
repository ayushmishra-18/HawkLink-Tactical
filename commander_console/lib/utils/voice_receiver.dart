import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';

class VoiceReceiver {
  final AudioPlayer _player = AudioPlayer();

  Future<void> playAudio(List<int> bytes) async {
    try {
      // Create source from bytes
      final source = BytesSource(Uint8List.fromList(bytes));
      await _player.play(source);
      debugPrint("VOICE RX: Playing ${bytes.length} bytes");
    } catch (e) {
      debugPrint("VOICE RX Error: $e");
    }
  }

  void dispose() {
    _player.dispose();
  }
}
