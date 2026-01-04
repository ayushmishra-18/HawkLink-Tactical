class InputValidator {
  
  // --- GENERAL VALIDATION ---
  static bool validatePacket(Map<String, dynamic> json) {
    if (!json.containsKey('type')) return false;

    // Sanitize string fields common to all packets
    if (json.containsKey('id') && !_isValidId(json['id'])) return false;
    if (json.containsKey('sender') && !_isValidId(json['sender'])) return false;

    try {
      switch (json['type']) {
        case 'STATUS':
          return _validateStatus(json);
        case 'ZEROIZE_REQUEST':
          return _validateZeroize(json);
        case 'CHAT':
          return _validateChat(json);
        default:
          return true; // Allow unknown types but maybe log warning? For strict mode, return false.
      }
    } catch (e) {
      return false; // Type mismatch or other parsing error
    }
  }

  // --- SPECIFIC PACKET VALIDATORS ---

  static bool _validateStatus(Map<String, dynamic> json) {
    // Required fields check
    if (!json.containsKey('lat') || !json.containsKey('lng')) return false;
    
    // GPS Range
    final double lat = (json['lat'] as num).toDouble();
    final double lng = (json['lng'] as num).toDouble();
    if (lat < -90 || lat > 90) return false;
    if (lng < -180 || lng > 180) return false;

    // Vital Signs Range (Sanity Check to prevent buffer/logic errors)
    if (json.containsKey('bpm')) {
      final int bpm = json['bpm'];
      if (bpm < 0 || bpm > 300) return false; // Dead or exploding heart
    }
    if (json.containsKey('bat')) {
      final int bat = json['bat'];
      if (bat < 0 || bat > 100) return false;
    }

    return true;
  }

  static bool _validateZeroize(Map<String, dynamic> json) {
    if (!json.containsKey('target')) return false;
    if (!json.containsKey('timestamp')) return false;
    // Signature presence is checked by CommandVerifier/Signer separately
    return true;
  }
  
  static bool _validateChat(Map<String, dynamic> json) {
    if (!json.containsKey('content')) return false;
    String content = json['content'];
    if (content.length > 1024) return false; // Max message length check
    return true;
  }

  // --- HELPER METHODS ---

  static bool _isValidId(String id) {
    // Alpha-numeric, hyphens, underscores only. No special chars.
    final validChars = RegExp(r'^[a-zA-Z0-9\-_]+$');
    return validChars.hasMatch(id);
  }

  static String sanitizeString(String input) {
    // Remove potential control characters or dangerous formatting
    return input.replaceAll(RegExp(r'[<>]'), ''); 
  }
}
