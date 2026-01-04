import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart';

class CommandSigner {
  static RSAPrivateKey? _privateKey;

  static Future<void> loadKey() async {
    try {
      final pem = await File('certs/server-key.pem').readAsString();
      _privateKey = CryptoUtils.rsaPrivateKeyFromPem(pem);
    } catch (e) {
      print("ERROR LOADING SIGNING KEY: $e");
    }
  }

  static String? sign(Map<String, dynamic> data) {
    if (_privateKey == null) return null;
    
    // Sort keys to ensure deterministic canonical JSON
    final sortedData = Map.fromEntries(
      data.entries.toList()..sort((a, b) => a.key.compareTo(b.key))
    );
    final jsonString = jsonEncode(sortedData);
    final bytes = utf8.encode(jsonString);

    final signer = RSASigner(SHA256Digest(), '0609608648016503040201'); // PKCS1t v1.5 padding
    signer.init(true, PrivateKeyParameter<RSAPrivateKey>(_privateKey!));
    
    final sig = signer.generateSignature(Uint8List.fromList(bytes));
    return base64Encode(sig.bytes);
  }
}
