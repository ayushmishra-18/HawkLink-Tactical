import 'package:flutter/material.dart';

enum TriageCategory {
  MINIMAL,   // Green: Walking wounded (Minor injuries)
  DELAYED,   // Yellow: Serious but stable (Fractures, etc)
  IMMEDIATE, // Red: Life-threatening (Airway, Bleeding, Shock)
  EXPECTANT  // Black: Deceased or non-survivable
}

class TriageSystem {
  
  static TriageCategory assess(int heartRate, int spO2, bool isConscious) {
    // 0. Deceased / Expectant
    if (heartRate == 0) return TriageCategory.EXPECTANT;
    
    // 1. Immediate (Red) - Critical Vitals
    // Shock (HR > 120 or < 40), Hypoxia (SpO2 < 90)
    if (heartRate > 120 || heartRate < 40 || spO2 < 90 || !isConscious) {
      return TriageCategory.IMMEDIATE;
    }
    
    // 2. Delayed (Yellow) - Abnormal but stable
    if (heartRate > 100 || spO2 < 95) {
      return TriageCategory.DELAYED;
    }
    
    // 3. Minimal (Green) - Normal
    return TriageCategory.MINIMAL;
  }

  static Color getColor(TriageCategory cat) {
    switch (cat) {
      case TriageCategory.MINIMAL: return Colors.green;
      case TriageCategory.DELAYED: return Colors.orange;
      case TriageCategory.IMMEDIATE: return Colors.red;
      case TriageCategory.EXPECTANT: return Colors.black;
    }
  }

  static String getLabel(TriageCategory cat) {
    switch (cat) {
      case TriageCategory.MINIMAL: return "MINIMAL";
      case TriageCategory.DELAYED: return "DELAYED";
      case TriageCategory.IMMEDIATE: return "IMMEDIATE";
      case TriageCategory.EXPECTANT: return "EXPECTANT";
    }
  }
}
