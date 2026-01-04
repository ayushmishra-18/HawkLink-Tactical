import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

class SecureLogger {
  static const _storage = FlutterSecureStorage();
  static const _keyStorageKey = 'hawklink_log_key_v1';
  static Uint8List? _logKey;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    
    // Check if key exists
    String? b64Key = await _storage.read(key: _keyStorageKey);
    if (b64Key == null) {
      // Generate new 256-bit key
      final random = Random.secure();
      final keyBytes = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(255)));
      b64Key = base64Encode(keyBytes);
      await _storage.write(key: _keyStorageKey, value: b64Key);
    }
    
    _logKey = base64Decode(b64Key);
    _initialized = true;
  }

  static Future<void> log(String category, String message) async {
    if (!_initialized) await init();
    
    final timestamp = DateTime.now().toIso8601String();
    final logEntry = '$timestamp|$category|$message';
    final encrypted = _encrypt(utf8.encode(logEntry));
    
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/hawklink_secure.log');
    await file.writeAsString('${base64Encode(encrypted)}\n', mode: FileMode.append);
  }

  static Future<List<String>> readLogs() async {
    if (!_initialized) await init();
    
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/hawklink_secure.log');
    if (!file.existsSync()) return [];
    
    final lines = await file.readAsLines();
    final logs = <String>[];
    
    for (var line in lines) {
      try {
        final decryptedBytes = _decrypt(base64Decode(line));
        logs.add(utf8.decode(decryptedBytes));
      } catch (e) {
        logs.add("ERR: TAMPERED OR CORRUPT LOG ENTRY");
      }
    }
    return logs;
  }

  // AES-GCM Encryption
  static Uint8List _encrypt(Uint8List plaintext) {
    if (_logKey == null) throw Exception("Log Key not loaded");

    final random = Random.secure();
    final nonce = Uint8List.fromList(List<int>.generate(12, (_) => random.nextInt(255))); // 96-bit nonce
    
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(_logKey!), 128, nonce, Uint8List(0));
    cipher.init(true, params);
    
    final ciphertext = cipher.process(plaintext);
    
    // Return nonce + ciphertext
    final payload = Uint8List(nonce.length + ciphertext.length);
    payload.setAll(0, nonce);
    payload.setAll(nonce.length, ciphertext);
    return payload;
  }

  static Uint8List _decrypt(Uint8List payload) {
    if (_logKey == null) throw Exception("Log Key not loaded");
    
    final nonce = payload.sublist(0, 12);
    final ciphertext = payload.sublist(12);
    
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(_logKey!), 128, nonce, Uint8List(0));
    cipher.init(false, params);
    
    return cipher.process(ciphertext);
  }
}
