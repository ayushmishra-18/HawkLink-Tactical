import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart'; // For RSA types

void main() async {
  print("Generating HawkLink Security Certificates (Self-Signed P2P)...");

  final certsDir = Directory('certs');
  if (!certsDir.existsSync()) {
    certsDir.createSync();
  }

  // 1. Generate Server Certificate
  print("Generating Server Cert...");
  final serverPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final serverPriv = serverPair.privateKey as RSAPrivateKey;
  final serverPub = serverPair.publicKey as RSAPublicKey;
  
  final serverKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(serverPriv);
  final serverCsr = X509Utils.generateRsaCsrPem({
    'CN': 'commander-console',
    'O': 'HawkLink Corp',
  }, serverPriv, serverPub);

  final serverCert = X509Utils.generateSelfSignedCertificate(
    serverPriv,
    serverCsr,
    365,
  );

  File('certs/server-key.pem').writeAsStringSync(serverKeyPem);
  File('certs/server-cert.pem').writeAsStringSync(serverCert);
  print("✔ Server Cert Generated");

  // 2. Generate Client Certificate
  print("Generating Client Cert...");
  final clientPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final clientPriv = clientPair.privateKey as RSAPrivateKey;
  final clientPub = clientPair.publicKey as RSAPublicKey;

  final clientKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(clientPriv);
  final clientCsr = X509Utils.generateRsaCsrPem({
    'CN': 'soldier-unit-generic',
    'O': 'HawkLink Corp',
  }, clientPriv, clientPub);

  final clientCert = X509Utils.generateSelfSignedCertificate(
    clientPriv,
    clientCsr,
    365,
  );

  File('certs/client-key.pem').writeAsStringSync(clientKeyPem);
  File('certs/client-cert.pem').writeAsStringSync(clientCert);
  print("✔ Client Cert Generated");
  
  File('certs/ca-cert.pem').writeAsStringSync(serverCert);
}
