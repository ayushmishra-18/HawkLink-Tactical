import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'dart:math';

class AuthProvider {
  static const _storage = FlutterSecureStorage();
  static const _passKey = 'hawklink_commander_pass_v1';
  static const _saltKey = 'hawklink_commander_salt_v1';
  
  // Checks if a password is set
  static Future<bool> isPasswordSet() async {
    final pass = await _storage.read(key: _passKey);
    return pass != null;
  }

  // Sets a new password
  static Future<void> setPassword(String password) async {
    final salt = _generateSalt();
    final hash = _hashPassword(password, salt);
    
    await _storage.write(key: _saltKey, value: base64Encode(salt));
    await _storage.write(key: _passKey, value: base64Encode(hash));
  }

  // Verifies password
  static Future<bool> verifyPassword(String password) async {
    final storedHashB64 = await _storage.read(key: _passKey);
    final storedSaltB64 = await _storage.read(key: _saltKey);
    
    if (storedHashB64 == null || storedSaltB64 == null) return false;
    
    final salt = base64Decode(storedSaltB64);
    final storedHash = base64Decode(storedHashB64);
    
    final computedHash = _hashPassword(password, salt);
    
    // Constant time comparison to prevent timing attacks
    return _constantTimeCompare(storedHash, computedHash);
  }
  
  // PBKDF2 Hashing
  static Uint8List _hashPassword(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, 10000, 32)); // 10k iterations, 32 byte output
    return pbkdf2.process(utf8.encode(password));
  }
  
  static Uint8List _generateSalt() {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(255)));
  }

  static bool _constantTimeCompare(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}
