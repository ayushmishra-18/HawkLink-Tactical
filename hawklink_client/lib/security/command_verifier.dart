import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart';

class CommandVerifier {
  static RSAPublicKey? _serverPublicKey;

  static Future<void> loadKey() async {
    try {
      final pem = await rootBundle.loadString('assets/certs/ca-cert.pem');
      _serverPublicKey = CryptoUtils.rsaPublicKeyFromPem(pem);
    } catch (e) {
      print("ERROR LOADING VERIFICATION KEY: $e");
    }
  }

  static bool verify(Map<String, dynamic> data) {
    if (_serverPublicKey == null || !data.containsKey('signature')) return false;

    final signature = data['signature'];
    
    // Construct payload without signature for verification
    final payload = Map<String, dynamic>.from(data);
    payload.remove('signature');
    
    // Sort keys to ensure deterministic canonical JSON (must match signer)
    final sortedData = Map.fromEntries(
      payload.entries.toList()..sort((a, b) => a.key.compareTo(b.key))
    );
    final jsonString = jsonEncode(sortedData);
    final bytes = utf8.encode(jsonString);

    final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
    signer.init(false, PublicKeyParameter<RSAPublicKey>(_serverPublicKey!));
    
    try {
      final sigBytes = base64Decode(signature);
      final signatureObj = RSASignature(Uint8List.fromList(sigBytes));
      return signer.verifySignature(Uint8List.fromList(bytes), signatureObj);
    } catch(e) {
      return false;
    }
  }
}
