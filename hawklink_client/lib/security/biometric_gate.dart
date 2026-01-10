import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class BiometricGate {
  static final LocalAuthentication _auth = LocalAuthentication();
  static int _failedAttempts = 0;
  static String lastError = "";
  static DateTime? _lockoutUntil;
  
  /// Check if biometric hardware is available
  static Future<bool> canAuthenticate() async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } catch (e) {
      lastError = "Hardware Check Error: $e";
      return false;
    }
  }

  /// Authenticate user with biometrics
  static Future<bool> authenticate() async {
    lastError = ""; // Reset
    // 0. Check for enrolled biometrics first
    try {
      final List<BiometricType> availableBiometrics = await _auth.getAvailableBiometrics();
      if (availableBiometrics.isEmpty) {
         debugPrint("No biometrics enrolled - Bypassing Gate");
         return true; 
      }
    } catch (e) {
      lastError = "Hardware Check Failed: $e";
      return true; // Weak fail-open for dev
    }

    // Check if in lockout period
    if (_lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!)) {
      final remaining = _lockoutUntil!.difference(DateTime.now()).inMinutes;
      lastError = "Locked out. Try again in $remaining min.";
      throw PlatformException(
        code: 'LOCKED_OUT',
        message: lastError,
      );
    }
    
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: 'Authenticate to access HawkLink Tactical',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,  // Allow PIN/Pattern fallback
          useErrorDialogs: true,
          sensitiveTransaction: true,
        ),
      );
      
      if (authenticated) {
        _failedAttempts = 0;  // Reset on success
        return true;
      } else {
        lastError = "User cancelled or failed verification.";
        _handleFailedAttempt();
        return false;
      }
    } on PlatformException catch (e) {
      lastError = "Auth Error: ${e.code} - ${e.message}";
      // Specific error codes for "Not Available" / "Not Enrolled"
      if (e.code == 'NotAvailable' || e.code == 'NotEnrolled' || e.code == 'no_biometrics_available') {
        return true; // Bypass
      }
      _handleFailedAttempt();
      return false;
    }
  }
  
  static void _handleFailedAttempt() {
    _failedAttempts++;
    if (_failedAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(minutes: 5));
      _failedAttempts = 0;
    }
  }
}
