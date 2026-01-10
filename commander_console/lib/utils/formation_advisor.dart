import '../models.dart'; // For SoldierUnit class

class FormationAdvisor {
  
  static AnalysisResult analyze(List<SoldierUnit> units) {
    if (units.isEmpty) return AnalysisResult("NO UNITS", 0.0, "Cannot analyze empty squad.");
    if (units.length < 2) return AnalysisResult("SINGLE UNIT", 1.0, "Standard free-roam protocol.");

    int medics = units.where((u) => u.role == "MEDIC").length;
    int snipers = units.where((u) => u.role == "SNIPER").length;
    int assaults = units.where((u) => u.role == "ASSAULT").length;

    // 1. VIP PROTECTION (DIAMOND)
    // Trigger: 1 Medic present with >2 escorts
    if (medics == 1 && units.length >= 3) {
      return AnalysisResult(
        "DIAMOND (VIP)", 
        0.95, 
        "High-Value Asset (MEDIC) detected. Recommendation: Diamond formation to provide 360° coverage for the Medic."
      );
    }

    // 2. OVERWATCH SPLIT (BOUNDING)
    // Trigger: Snipers present
    if (snipers > 0) {
      return AnalysisResult(
        "OVERWATCH SPLIT",
        0.88,
        "Long-range assets (SNIPERS) detected. Recommendation: Split element. Snipers take high ground/rear, Assaults advance."
      );
    }

    // 3. HEAVY ASSAULT (WEDGE)
    // Trigger: Mostly Assaults
    if (assaults >= units.length / 2) {
      return AnalysisResult(
        "ASSAULT WEDGE",
        0.92,
        "Heavy firepower concentration. Recommendation: Wedge formation for maximum frontal firepower and flank security."
      );
    }

    // Default
    return AnalysisResult(
      "RANGER FILE",
      0.60,
      "Mixed composition. Recommendation: Standard Ranger File for speed and control."
    );
  }
}

class AnalysisResult {
  final String formationName;
  final double confidence;
  final String description;

  AnalysisResult(this.formationName, this.confidence, this.description);
}
