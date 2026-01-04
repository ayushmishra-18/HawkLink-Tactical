import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/api.dart' as p_api; // Alias to avoid conflicts if needed

class SecureChannel {
  final Uint8List _sessionKey;
  int _sendCounter = 0;
  int _receiveCounter = 0;

  SecureChannel(this._sessionKey);

  /// Encrypts plaintext using AES-256-GCM with a random nonce.
  /// Authentication Tag is 128-bit.
  /// Additional Authenticated Data (AAD) includes a sequence counter to prevent replay attacks.
  EncryptedMessage encrypt(String plaintext) {
    // 1. Generate random 12-byte Nonce
    final nonce = _generateRandomBytes(12);

    // 2. Prepare AAD with Sequence Counter (Replay Protection)
    final aad = Uint8List(8 + 'HawkLink'.length);
    aad.setRange(0, 'HawkLink'.length, utf8.encode('HawkLink'));
    ByteData.view(aad.buffer).setUint64('HawkLink'.length, _sendCounter++, Endian.big);

    // 3. Setup AES-GCM
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(_sessionKey),
      128, // 128-bit MAC size
      nonce,
      aad,
    );
    cipher.init(true, params); // true = encrypt

    // 4. Encrypt
    final input = utf8.encode(plaintext);
    final output = cipher.process(input);

    return EncryptedMessage(nonce, output);
  }

  /// Decrypts a message using AES-256-GCM.
  /// Verifies the Authentication Tag and the Sequence Counter in AAD.
  String decrypt(EncryptedMessage msg) {
    // 1. Reconstruct AAD with Expected Sequence Counter
    final aad = Uint8List(8 + 'HawkLink'.length);
    aad.setRange(0, 'HawkLink'.length, utf8.encode('HawkLink'));
    ByteData.view(aad.buffer).setUint64('HawkLink'.length, _receiveCounter, Endian.big);

    // 2. Setup AES-GCM
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(_sessionKey),
      128, // 128-bit MAC size
      msg.nonce,
      aad,
    );
    cipher.init(false, params); // false = decrypt

    // 3. Decrypt & Verify
    try {
      final plaintextBytes = cipher.process(msg.ciphertext);
      _receiveCounter++; // Only increment if successful
      return utf8.decode(plaintextBytes);
    } catch (e) {
      throw SecurityException("Decryption failed: Integrity check or Replay protection error.");
    }
  }

  Uint8List _generateRandomBytes(int length) {
    final random = SecureRandom('Fortuna')..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => DateTime.now().microsecondsSinceEpoch % 255))));
    return random.nextBytes(length);
  }
}

class EncryptedMessage {
  final Uint8List nonce;
  final Uint8List ciphertext;

  EncryptedMessage(this.nonce, this.ciphertext);

  // Serialize: [1 byte nonce_len][nonce][ciphertext]
  Uint8List toBytes() {
    final bytes = Uint8List(1 + nonce.length + ciphertext.length);
    bytes[0] = nonce.length;
    bytes.setRange(1, 1 + nonce.length, nonce);
    bytes.setRange(1 + nonce.length, bytes.length, ciphertext);
    return bytes;
  }

  // Deserialize
  static EncryptedMessage fromBytes(Uint8List data) {
    final nonceLen = data[0];
    final nonce = data.sublist(1, 1 + nonceLen);
    final ciphertext = data.sublist(1 + nonceLen);
    return EncryptedMessage(nonce, ciphertext);
  }
}

class SecurityException implements Exception {
  final String message;
  SecurityException(this.message);
  @override
  String toString() => "SecurityException: $message";
}
