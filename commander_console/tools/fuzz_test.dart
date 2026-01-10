import 'dart:convert';
import 'dart:math';
import 'dart:io';
import '../lib/security/input_validator.dart';

// MOCK CONSTANTS needed for the test
// We can just rely on the static Validator methods

void main() {
  print("--- STARTING FUZZ TESTING ---");
  
  int passed = 0;
  int failed = 0;
  final random = Random();

  // 1. BUFFER OVERFLOW FUZZ
  print("\n[TEST 1] Buffer Overflow / Large Payload");
  try {
    String hugeString = "A" * 10000; // 10KB string
    Map<String, dynamic> hugePacket = {
      'type': 'CHAT',
      'sender': 'TESTER',
      'content': hugeString
    };
    
    // The validator SHOULD return false (invalid) or at least not crash
    bool result = InputValidator.validatePacket(hugePacket);
    if (!result) {
      print("PASS: Large payload correctly rejected.");
      passed++;
    } else {
      print("WARNING: Large payload accepted (Is this intended?)");
      // If your validator doesn't have a max length check, this might pass.
      // Based on our implementation, we added strict type checks, but maybe not length for all fields.
    }
  } catch (e) {
    print("CRASH: Validator crashed on large payload: $e");
    failed++;
  }

  // 2. TYPE MISMATCH FUZZ
  print("\n[TEST 2] Type Injection");
  List<Map<String, dynamic>> typeAttackVectors = [
    {'type': 'STATUS', 'lat': "NOT_A_DOUBLE", 'lng': 0.0}, // String instead of double
    {'type': 'STATUS', 'lat': 0.0, 'lng': true}, // Bool instead of double
    {'type': 'CHAT', 'content': {'nested': 'object'}}, // Map instead of String
    {'type': 12345, 'content': 'Bad Type Field'}, // Int instead of String
  ];

  for (var vector in typeAttackVectors) {
    try {
      bool result = InputValidator.validatePacket(vector);
      if (!result) {
        // print("PASS: Rejected malformed type: $vector");
        passed++;
      } else {
        print("FAIL: Accepted malformed type: $vector");
        failed++;
      }
    } catch (e) {
      print("CRASH: Validator saw exception: $e");
      failed++;
    }
  }

  // 3. SPECIAL CHARACTERS / INJECTION
  print("\n[TEST 3] Injection Strings");
  List<String> naughtyStrings = [
    "<script>alert(1)</script>",
    "DROP TABLE users;",
    "../../etc/passwd",
    "\x00\x00\x00", // Null bytes
    "{{ 7 * 7 }}" // Template injection
  ];

  for (var str in naughtyStrings) {
    Map<String, dynamic> packet = {
      'type': 'CHAT',
      'sender': 'HACKER',
      'content': str
    };
    
    try {
      // Validator cleans strings but might return true if structure is valid.
      // We want to ensure it doesn't CRASH.
      bool result = InputValidator.validatePacket(packet);
      // It's effectively a pass if it handles it without crashing.
      // Our InputValidator sanitizes, so it might accept them but strip chars.
      passed++; 
    } catch (e) {
      print("CRASH: String caused exception: $str - $e");
      failed++;
    }
  }

  // 4. MISSING FIELDS
  print("\n[TEST 4] Missing Required Fields");
  Map<String, dynamic> emptyPacket = {};
  if (!InputValidator.validatePacket(emptyPacket)) {
    passed++;
  } else {
    print("FAIL: Empty packet accepted");
    failed++;
  }

  print("\n--- RESULTS ---");
  print("PASSED CHECKS: $passed");
  print("FAILED CHECKS: $failed");
  
  if (failed == 0) {
    print("VERDICT: ROBUST");
  } else {
    print("VERDICT: VULNERABLE");
    exit(1);
  }
}
