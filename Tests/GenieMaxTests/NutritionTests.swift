import Testing
import Foundation
@testable import GenieMax

// s#7 p14c — photo-nutrition breakdown data model (P1/P2).

@Test func nutritionSumsItemsNilSafe() {
  let items = [
    FoodItem(id: "1", name: "Rice", amountG: 200, kcal: 280, proteinG: 5, carbsG: 62, fatG: 0.5, fiberG: 1),
    FoodItem(id: "2", name: "Fried chicken", amountG: 150, kcal: 410, proteinG: 32, carbsG: 18, fatG: 22, satFatG: 6),
  ]
  let n = NutritionFacts.sum(items)
  #expect(n.kcal == 690)
  #expect(n.proteinG == 37)
  #expect(n.carbsG == 80)
  #expect(n.fatG == 22.5)
  #expect(n.fiberG == 1)            // only item 1 reported fiber → summed from it alone
  #expect(n.satFatG == 6)           // only item 2 reported sat-fat
  #expect(n.sodiumMg == nil)        // neither reported sodium → nil, not 0
}

@Test func foodItemScalesWithPortion() {
  let i = FoodItem(id: "1", name: "Rice", amountG: 200, kcal: 280, proteinG: 5, carbsG: 62, fatG: 0.5, confidence: 0.8)
  let half = i.scaled(toGrams: 100)
  #expect(half.amountG == 100)
  #expect(half.kcal == 140)
  #expect(half.proteinG == 2.5)
  #expect(half.confidence == 0.8)   // confidence is not scaled
  // no amount → can't scale → unchanged
  let noAmt = FoodItem(id: "2", name: "x", kcal: 100)
  #expect(noAmt.scaled(toGrams: 50).kcal == 100)
}

@Test func macroTargetsAreSaneAndBodyweightAnchored() {
  let t = MacroTargets.from(targetKcal: 2200, weightKg: 80)
  #expect(t.proteinG == 1.6 * 80)                       // 128 g — bodyweight-anchored
  #expect(abs(t.fatG - 0.27 * 2200 / 9) < 0.01)         // ~66 g
  #expect(t.carbsG > 0)
  // the three macros reconstruct ~the calorie target (4/4/9 kcal per g)
  let reKcal = t.proteinG * 4 + t.carbsG * 4 + t.fatG * 9
  #expect(abs(reKcal - 2200) < 1)
  #expect(t.fiberG > 25 && t.fiberG < 35)               // ~31 g for 2200 kcal
  #expect(t.sodiumLimitMg == 2300)
  // heavier person → higher protein target
  #expect(MacroTargets.from(targetKcal: 2200, weightKg: 100).proteinG > t.proteinG)
}

@Test func macroTargetsFallBackWithoutWeight() {
  let t = MacroTargets.from(targetKcal: 2000, weightKg: 0)
  #expect(t.proteinG > 0)                               // 15%-kcal fallback, not zero
  #expect(t.carbsG > 0 && t.fatG > 0)
}

@Test func mealParseRichBreakdown() {
  let json = """
  here is your meal: {"name":"Chicken rice plate","items":[
    {"name":"Jasmine rice","amountG":200,"kcal":260,"protein":5,"carbs":57,"fat":0.5,"fiber":1,"confidence":0.85},
    {"name":"Fried chicken","amountG":150,"kcal":410,"protein":32,"carbs":18,"fat":22,"satFat":6,"sodium":540,"confidence":0.7}],
    "healthScore":61,"tags":["high-protein","gluten-free"]}
  """
  let m = MealParse.parse(json)
  #expect(m != nil)
  #expect(m?.items.count == 2)
  #expect(m?.nutrition.kcal == 670)
  #expect(m?.nutrition.proteinG == 37)
  #expect(m?.nutrition.satFatG == 6)            // only the chicken reported it
  #expect(m?.healthScore == 61)
  #expect(m?.tags == ["high-protein", "gluten-free"])
}

@Test func intakeEntryReconstructsEstimate() {
  // rich entry → items preserved
  let rich = IntakeEntry(id: "a", meal: "Lunch", name: "Plate", kcal: 690, ts: 1,
    items: [FoodItem(id: "1", name: "Rice", kcal: 280, proteinG: 5)],
    nutrition: NutritionFacts(kcal: 690, proteinG: 37), healthScore: 70, tags: ["keto"])
  let e1 = rich.mealEstimate
  #expect(e1.items.count == 1 && e1.healthScore == 70 && e1.tags == ["keto"])
  // plain old entry (no breakdown) → a single synthetic item from kcal
  let plain = IntakeEntry(id: "b", meal: "Snack", name: "Latte", kcal: 120, ts: 1)
  let e2 = plain.mealEstimate
  #expect(e2.items.count == 1 && e2.nutrition.kcal == 120 && e2.items.first?.proteinG == nil)
}

@Test func commonFoodAndSingleEstimateCarryMacros() {
  let rice = CommonFoods.items.first { $0.name.hasPrefix("Rice") }!
  let est = rice.estimate
  #expect(est.nutrition.kcal == rice.kcal)
  #expect(est.nutrition.proteinG == rice.protein && est.nutrition.carbsG == rice.carbs)
  let s = MealEstimate.single(name: "Yogurt", kcal: 100, proteinG: 10, carbsG: 12, fatG: 0)
  #expect(s.items.count == 1 && s.nutrition.proteinG == 10)
}

@Test func mealParseFlatFallbackAndGarbage() {
  let flat = MealParse.parse(#"{"name":"Latte","kcal":120}"#)   // old shape → one item
  #expect(flat?.items.count == 1)
  #expect(flat?.nutrition.kcal == 120)
  #expect(flat?.healthScore == nil)
  #expect(MealParse.parse("no json here") == nil)               // unusable → nil
  #expect(MealParse.parse(#"{"name":"x"}"#) == nil)             // no kcal anywhere → nil
}

// Backward-compat: an old kcal-only entry JSON (no items/nutrition/healthScore/tags) must still decode.
@Test func oldIntakeEntryDecodesWithoutNutritionFields() throws {
  let json = #"{"id":"a","meal":"Lunch","name":"Rice","kcal":280,"ts":1700000000}"#
  let e = try JSONDecoder().decode(IntakeEntry.self, from: Data(json.utf8))
  #expect(e.kcal == 280)
  #expect(e.items == nil && e.nutrition == nil && e.healthScore == nil && e.tags == nil)
  // and a rich entry round-trips
  let rich = IntakeEntry(id: "b", meal: "Dinner", name: "Plate", kcal: 690, ts: 1,
    items: [FoodItem(id: "1", name: "Rice", kcal: 280, proteinG: 5)],
    nutrition: NutritionFacts(kcal: 690, proteinG: 37), healthScore: 72, tags: ["gluten-free"])
  let back = try JSONDecoder().decode(IntakeEntry.self, from: JSONEncoder().encode(rich))
  #expect(back == rich)
}
