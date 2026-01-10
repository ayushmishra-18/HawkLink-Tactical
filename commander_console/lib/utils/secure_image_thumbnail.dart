import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../security/secure_logger.dart';

class SecureImageThumbnail extends StatefulWidget {
  final String path;
  final BoxFit fit;

  const SecureImageThumbnail({super.key, required this.path, this.fit = BoxFit.cover});

  @override
  State<SecureImageThumbnail> createState() => _SecureImageThumbnailState();
}

class _SecureImageThumbnailState extends State<SecureImageThumbnail> {
  Uint8List? _imageData;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      if (widget.path.endsWith('.enc')) {
        final file = File(widget.path);
        if (!await file.exists()) {
          setState(() { _isLoading = false; _hasError = true; });
          return;
        }
        final encryptedBytes = await file.readAsBytes();
        final decrypted = await SecureLogger.decryptData(encryptedBytes);
        if (mounted) {
          setState(() {
            _imageData = decrypted;
            _isLoading = false;
          });
        }
      } else {
        // Legacy plaintext support
        setState(() { _isLoading = false; });
      }
    } catch (e) {
      debugPrint("Error loading secure image: $e");
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        color: Colors.red.withOpacity(0.2),
        child: const Center(child: Icon(Icons.broken_image, color: Colors.red)),
      );
    }
    
    if (_isLoading) {
      return Container(
        color: Colors.black12,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_imageData != null) {
      return Image.memory(_imageData!, fit: widget.fit);
    } else {
      return Image.file(File(widget.path), fit: widget.fit);
    }
  }
}
