import Foundation

/// P1 nutrition breakdown (s#7 p14c). Frontier photo-nutrition apps (Cal AI, SnapCalorie) split a plate into
/// per-INGREDIENT items, each with its own macros, and roll them up to the meal total. All macro fields are optional
/// so an old kcal-only entry still decodes, and so an item the AI couldn't break down still logs. Macros (P/C/F +
/// sugar/fiber/sat-fat/sodium = the FDA Nutrition-Facts core) are what AI vision estimates reliably; deeper micros
/// (vitamins/minerals) are intentionally NOT stored here — they're low-confidence from a photo.
public struct FoodItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var amountG: Double?        // estimated portion in grams (editable; scaling it scales the macros)
  public var kcal: Double
  public var proteinG: Double?
  public var carbsG: Double?
  public var fatG: Double?
  public var sugarG: Double?
  public var fiberG: Double?
  public var satFatG: Double?
  public var sodiumMg: Double?
  public var confidence: Double?     // 0–1 AI confidence in this item's estimate
  public init(id: String, name: String, amountG: Double? = nil, kcal: Double,
              proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil,
              sugarG: Double? = nil, fiberG: Double? = nil, satFatG: Double? = nil,
              sodiumMg: Double? = nil, confidence: Double? = nil) {
    self.id = id; self.name = name; self.amountG = amountG; self.kcal = kcal
    self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
    self.sugarG = sugarG; self.fiberG = fiberG; self.satFatG = satFatG
    self.sodiumMg = sodiumMg; self.confidence = confidence
  }
  /// Scale every value to a new portion (used when the user edits the grams). nil amounts → unchanged.
  public func scaled(toGrams g: Double) -> FoodItem {
    guard let a = amountG, a > 0, g > 0 else { return self }
    let f = g / a
    func s(_ v: Double?) -> Double? { v.map { $0 * f } }
    return FoodItem(id: id, name: name, amountG: g, kcal: kcal * f,
                    proteinG: s(proteinG), carbsG: s(carbsG), fatG: s(fatG),
                    sugarG: s(sugarG), fiberG: s(fiberG), satFatG: s(satFatG),
                    sodiumMg: s(sodiumMg), confidence: confidence)
  }
}

/// Rolled-up nutrition totals for one entry/meal (the sum of its `FoodItem`s, or a single AI estimate). A field is
/// nil only when NONE of the items reported it.
public struct NutritionFacts: Codable, Equatable, Sendable {
  public var kcal: Double
  public var proteinG: Double?, carbsG: Double?, fatG: Double?
  public var sugarG: Double?, fiberG: Double?, satFatG: Double?, sodiumMg: Double?, cholesterolMg: Double?
  public init(kcal: Double, proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil,
              sugarG: Double? = nil, fiberG: Double? = nil, satFatG: Double? = nil,
              sodiumMg: Double? = nil, cholesterolMg: Double? = nil) {
    self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
    self.sugarG = sugarG; self.fiberG = fiberG; self.satFatG = satFatG
    self.sodiumMg = sodiumMg; self.cholesterolMg = cholesterolMg
  }
  /// Sum food items → one totals block. Each macro is summed across only the items that report it (nil if none do).
  public static func sum(_ items: [FoodItem]) -> NutritionFacts {
    func tot(_ key: (FoodItem) -> Double?) -> Double? {
      let vs = items.compactMap(key); return vs.isEmpty ? nil : vs.reduce(0, +)
    }
    return NutritionFacts(kcal: items.reduce(0) { $0 + $1.kcal },
      proteinG: tot { $0.proteinG }, carbsG: tot { $0.carbsG }, fatG: tot { $0.fatG },
      sugarG: tot { $0.sugarG }, fiberG: tot { $0.fiberG }, satFatG: tot { $0.satFatG },
      sodiumMg: tot { $0.sodiumMg })
  }
}

/// P2 — daily macro targets (grams) derived from the user's calorie target + bodyweight. Protein is bodyweight-
/// anchored (1.6 g/kg, a sound general-fitness target); fat ≈ 27% of kcal; carbs take the remainder. Sugar / sat-fat
/// / sodium are upper LIMITS (FDA/AHA guidance), not goals. Pure → unit-tested; no Profile/Calendar dependency.
public struct MacroTargets: Codable, Equatable, Sendable {
  public var kcal: Double
  public var proteinG: Double, fatG: Double, carbsG: Double, fiberG: Double
  public var sugarLimitG: Double, satFatLimitG: Double, sodiumLimitMg: Double
  public static func from(targetKcal: Double, weightKg: Double) -> MacroTargets {
    let kcal = max(0, targetKcal)
    let protein = max(0, weightKg > 0 ? 1.6 * weightKg : 0.15 * kcal / 4)   // 1.6 g/kg, fallback 15% kcal
    let fatKcal = 0.27 * kcal
    let proteinKcal = protein * 4
    let carbKcal = max(0, kcal - proteinKcal - fatKcal)
    return MacroTargets(kcal: kcal,
      proteinG: protein, fatG: fatKcal / 9, carbsG: carbKcal / 4,
      fiberG: kcal / 1000 * 14,                 // 14 g per 1000 kcal (IOM)
      sugarLimitG: 0.10 * kcal / 4,             // added sugar < 10% kcal (WHO/AHA)
      satFatLimitG: 0.10 * kcal / 9,            // saturated fat < 10% kcal
      sodiumLimitMg: 2300)                      // FDA upper limit
  }
}

/// F1 — a single food-intake entry (one tap = one entry). Stays low-friction: `name` + `kcal` are the only required
/// fields. The optional `items` (per-ingredient breakdown), `nutrition` (rolled-up macros), `healthScore`, and
/// `tags` were added in s#7 p14c for the photo-nutrition breakdown — all optional so old entries decode unchanged.
public struct IntakeEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var meal: String        // "Breakfast" | "Lunch" | "Dinner" | "Snack"
  public var name: String
  public var kcal: Double
  public var ts: Double
  public var items: [FoodItem]?         // per-ingredient breakdown (AI-photo / detailed entries); nil for a simple kcal log
  public var nutrition: NutritionFacts? // rolled-up macros for the whole entry
  public var healthScore: Int?          // 0–100 (Cal-AI-style "how healthy is this meal")
  public var tags: [String]?            // dietary tags + allergens: "vegan", "keto", "gluten-free", "contains: nuts"
  public init(id: String, meal: String, name: String, kcal: Double, ts: Double,
              items: [FoodItem]? = nil, nutrition: NutritionFacts? = nil,
              healthScore: Int? = nil, tags: [String]? = nil) {
    self.id = id; self.meal = meal; self.name = name; self.kcal = kcal; self.ts = ts
    self.items = items; self.nutrition = nutrition; self.healthScore = healthScore; self.tags = tags
  }
}

/// The parsed result of an AI meal estimate (photo or text) before it's committed to an `IntakeEntry`.
public struct MealEstimate: Equatable, Sendable {
  public var name: String
  public var items: [FoodItem]
  public var nutrition: NutritionFacts
  public var healthScore: Int?
  public var tags: [String]
  public init(name: String, items: [FoodItem], nutrition: NutritionFacts, healthScore: Int? = nil, tags: [String] = []) {
    self.name = name; self.items = items; self.nutrition = nutrition; self.healthScore = healthScore; self.tags = tags
  }
}

/// Pure parser for the coach's meal JSON → `MealEstimate`. Tolerant of stray text around the JSON. Accepts BOTH the
/// rich shape (`items[]` + healthScore + tags, the photo-breakdown path) and the old flat `{name,kcal}` (→ a single
/// item) so a non-vision / older model still logs. Returns nil only when there's no usable calorie figure at all.
public enum MealParse {
  public static func parse(_ text: String) -> MealEstimate? {
    guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
          let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any] else { return nil }
    func num(_ a: Any?) -> Double? {
      if let d = a as? Double { return d }; if let i = a as? Int { return Double(i) }
      if let s = a as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }; return nil
    }
    let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Meal"
    var items: [FoodItem] = []
    if let arr = obj["items"] as? [[String: Any]] {
      for (i, it) in arr.enumerated() {
        guard let k = num(it["kcal"]), k > 0 else { continue }
        items.append(FoodItem(id: "it\(i)", name: (it["name"] as? String) ?? "Item",
          amountG: num(it["amountG"]) ?? num(it["grams"]), kcal: k,
          proteinG: num(it["protein"]), carbsG: num(it["carbs"]), fatG: num(it["fat"]),
          sugarG: num(it["sugar"]), fiberG: num(it["fiber"]),
          satFatG: num(it["satFat"]) ?? num(it["saturatedFat"]),
          sodiumMg: num(it["sodium"]), confidence: num(it["confidence"])))
      }
    }
    if items.isEmpty {                              // flat fallback (old {name,kcal} or single-food top-level macros)
      guard let k = num(obj["kcal"]), k > 0 else { return nil }
      items = [FoodItem(id: "it0", name: name, amountG: num(obj["amountG"]), kcal: k,
        proteinG: num(obj["protein"]), carbsG: num(obj["carbs"]), fatG: num(obj["fat"]),
        sugarG: num(obj["sugar"]), fiberG: num(obj["fiber"]), satFatG: num(obj["satFat"]),
        sodiumMg: num(obj["sodium"]))]
    }
    var nutrition = NutritionFacts.sum(items)
    if let c = num(obj["cholesterol"]) { nutrition.cholesterolMg = c }
    let health = num(obj["healthScore"]).map { Int(max(0, min(100, $0.rounded()))) }
    let tags = (obj["tags"] as? [String])?.filter { !$0.isEmpty } ?? []
    return MealEstimate(name: name, items: items, nutrition: nutrition, healthScore: health, tags: tags)
  }
}

public extension MealEstimate {
  /// Build a one-item estimate (a common food / a barcode hit / a manual macro entry).
  static func single(name: String, kcal: Double, proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil,
                     sugarG: Double? = nil, fiberG: Double? = nil, satFatG: Double? = nil, sodiumMg: Double? = nil,
                     healthScore: Int? = nil, tags: [String] = []) -> MealEstimate {
    let item = FoodItem(id: "0", name: name, kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                        sugarG: sugarG, fiberG: fiberG, satFatG: satFatG, sodiumMg: sodiumMg)
    return MealEstimate(name: name, items: [item], nutrition: NutritionFacts.sum([item]), healthScore: healthScore, tags: tags)
  }
}

public extension IntakeEntry {
  /// Reconstruct a `MealEstimate` from a stored entry — for the Food-log detail view and for re-adding a recent food
  /// WITH its nutrition. Uses the stored per-item breakdown if present, else a single item from the rolled-up
  /// nutrition (or just kcal for an old plain entry).
  var mealEstimate: MealEstimate {
    let its: [FoodItem] = items ?? [FoodItem(id: "\(id)-0", name: name, kcal: nutrition?.kcal ?? kcal,
      proteinG: nutrition?.proteinG, carbsG: nutrition?.carbsG, fatG: nutrition?.fatG,
      sugarG: nutrition?.sugarG, fiberG: nutrition?.fiberG, satFatG: nutrition?.satFatG, sodiumMg: nutrition?.sodiumMg)]
    return MealEstimate(name: name, items: its, nutrition: nutrition ?? NutritionFacts.sum(its),
                        healthScore: healthScore, tags: tags ?? [])
  }
}

/// The four meal buckets (localized in the UI).
public enum Meal {
  public static let all = ["Breakfast", "Lunch", "Dinner", "Snack"]
}

/// A tiny curated list of common foods with rough macros (per the listed portion) — one-tap add, no database/network.
/// kcal + protein/carbs/fat (grams) so a quick-add still carries a nutrition breakdown.
public enum CommonFoods {
  public struct Item: Sendable, Equatable {
    public let name: String; public let kcal, protein, carbs, fat: Double
    public init(_ name: String, _ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double) {
      self.name = name; self.kcal = kcal; self.protein = protein; self.carbs = carbs; self.fat = fat
    }
    public var estimate: MealEstimate { .single(name: name, kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat) }
  }
  public static let items: [Item] = [
    .init("Rice (1 cup)", 200, 4, 45, 0.4), .init("Fried rice (plate)", 600, 12, 80, 22),
    .init("Noodle soup (bowl)", 380, 18, 50, 10), .init("Egg", 78, 6, 0.6, 5),
    .init("Chicken breast (100g)", 165, 31, 0, 3.6), .init("Pork (100g)", 240, 27, 0, 14),
    .init("Bread (slice)", 80, 3, 14, 1), .init("Banana", 105, 1.3, 27, 0.4),
    .init("Apple", 95, 0.5, 25, 0.3), .init("Coffee w/ milk", 60, 3, 6, 2.5),
    .init("Soda (can)", 140, 0, 39, 0), .init("Salad", 150, 3, 12, 10),
  ]
}
