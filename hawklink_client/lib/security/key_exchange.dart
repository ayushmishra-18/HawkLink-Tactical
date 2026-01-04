import 'dart:typed_data';
import 'dart:math';
import 'dart:convert';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/api.dart';

class KeyExchange {
  AsymmetricKeyPair<PublicKey, PrivateKey>? _keyPair;
  final ECDomainParameters _domainParams = ECDomainParameters('secp256r1');

  Future<AsymmetricKeyPair<PublicKey, PrivateKey>> generateKeyPair() async {
    final keyGen = ECKeyGenerator();
    final secureRandom = _getSecureRandom();
    
    keyGen.init(ParametersWithRandom(
      ECKeyGeneratorParameters(_domainParams),
      secureRandom,
    ));
    
    _keyPair = keyGen.generateKeyPair();
    return _keyPair!;
  }

  Uint8List getPublicKeyBytes() {
    if (_keyPair == null) throw StateError("Keys not generated");
    final pubKey = _keyPair!.publicKey as ECPublicKey;
    return pubKey.Q!.getEncoded(false);
  }

  Uint8List computeSharedSecret(Uint8List peerPublicKeyBytes) {
    if (_keyPair == null) throw StateError("Keys not generated");

    final curve = _domainParams.curve;
    final q = curve.decodePoint(peerPublicKeyBytes);
    final peerPublicKey = ECPublicKey(q, _domainParams);

    final agreement = ECDHBasicAgreement();
    agreement.init(_keyPair!.privateKey as ECPrivateKey);
    
    final secretBigInt = agreement.calculateAgreement(peerPublicKey);
    return _bigIntToBytes(secretBigInt);
  }

  Uint8List deriveSessionKey(Uint8List sharedSecret, String salt, String info) {
    final hkdf = HKDFKeyDerivator(SHA256Digest());
    hkdf.init(HkdfParameters(sharedSecret, 32, utf8.encode(salt), utf8.encode(info)));
    return hkdf.process(Uint8List(32)); 
  }
  
  SecureRandom _getSecureRandom() {
    final secureRandom = SecureRandom('Fortuna');
    final random = Random.secure();
    final seeds = List<int>.generate(32, (_) => random.nextInt(255));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  Uint8List _bigIntToBytes(BigInt number) {
    var hex = number.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    return Uint8List.fromList(List<int>.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i*2, i*2 + 2), radix: 16)));
  }
}
