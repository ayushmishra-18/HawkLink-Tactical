import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:pointycastle/export.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class EncryptedTileProvider extends TileProvider {
  static const _storage = FlutterSecureStorage();
  static Uint8List? _cachedKey;
  
  /// Get or generate tile encryption key
  static Future<Uint8List> _getEncryptionKey() async {
    if (_cachedKey != null) return _cachedKey!;
    
    String? keyB64 = await _storage.read(key: 'tile_encryption_key');
    
    if (keyB64 == null) {
      // Generate new key
      final key = Uint8List.fromList(List.generate(32, (i) => Random.secure().nextInt(256)));
      keyB64 = base64Encode(key);
      await _storage.write(key: 'tile_encryption_key', value: keyB64);
      _cachedKey = key;
    } else {
      _cachedKey = base64Decode(keyB64);
    }
    
    return _cachedKey!;
  }
  
  /// Encrypt tile data
  static Future<Uint8List> _encryptTile(Uint8List plaintext) async {
    final key = await _getEncryptionKey();
    final nonce = Uint8List.fromList(List.generate(12, (i) => Random.secure().nextInt(256)));
    
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0));
    cipher.init(true, params);
    
    final ciphertext = cipher.process(plaintext);
    
    // Prepend nonce to ciphertext
    return Uint8List.fromList([...nonce, ...ciphertext]);
  }
  
  /// Decrypt tile data
  static Future<Uint8List> _decryptTile(Uint8List encrypted) async {
    final key = await _getEncryptionKey();
    final nonce = encrypted.sublist(0, 12);
    final ciphertext = encrypted.sublist(12);
    
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0));
    cipher.init(false, params);
    
    return cipher.process(ciphertext);
  }
  
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final tileKey = '${coordinates.z}_${coordinates.x}_${coordinates.y}';
    
    // Try to load from encrypted cache
    return FutureProvider<Uint8List>(
      future: _loadOrDownloadTile(tileKey, coordinates, options),
    );
  }
  
  Future<Uint8List> _loadOrDownloadTile(
    String tileKey,
    TileCoordinates coordinates,
    TileLayer options,
  ) async {
    // Check cache first
    final cacheDir = await getApplicationDocumentsDirectory();
    final cacheFile = File('${cacheDir.path}/tiles/$tileKey.enc');
    
    if (await cacheFile.exists()) {
      try {
        final encrypted = await cacheFile.readAsBytes();
        return await _decryptTile(encrypted);
      } catch (e) {
        // Corrupt cache? Redownload
      }
    }
    
    // Download tile
    final url = options.urlTemplate!
      .replaceAll('{z}', coordinates.z.toString())
      .replaceAll('{x}', coordinates.x.toString())
      .replaceAll('{y}', coordinates.y.toString());
    
    final response = await http.get(Uri.parse(url));
    
    if (response.statusCode == 200) {
      // Encrypt and cache
      final encrypted = await _encryptTile(response.bodyBytes);
      await cacheFile.create(recursive: true);
      await cacheFile.writeAsBytes(encrypted);
      
      return response.bodyBytes;
    }
    
    throw Exception('Failed to load tile');
  }
}

class FutureProvider<T> extends ImageProvider<FutureProvider<T>> {
  final Future<Uint8List> future;
  
  FutureProvider({required this.future});
  
  @override
  Future<FutureProvider<T>> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<FutureProvider<T>>(this);
  }
  
  @override
  ImageStreamCompleter loadImage(FutureProvider<T> key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _loadAsync(FutureProvider<T> key, ImageDecoderCallback decode) async {
    final bytes = await future;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is FutureProvider<T> && other.future == future;
  }

  @override
  int get hashCode => future.hashCode;
}
