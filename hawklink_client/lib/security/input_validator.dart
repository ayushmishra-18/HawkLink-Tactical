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
        case 'TERRAIN':
          return _validateTerrain(json);
        case 'WAYPOINT':
          return _validateWaypoint(json);
        default:
          return true; 
      }
    } catch (e) {
      return false; 
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

  static bool _validateTerrain(Map<String, dynamic> json) {
    if (!json.containsKey('data')) return false;
    var data = json['data'];
    if(data['temp'] > 60.0 || data['temp'] < -50.0) return false; // Earth temps
    return true;
  }

  static bool _validateWaypoint(Map<String, dynamic> json) {
    if (json['action'] == 'ADD') {
       if(!json.containsKey('data')) return false;
       var d = json['data'];
       if(d['lat'] < -90 || d['lat'] > 90) return false;
    }
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
