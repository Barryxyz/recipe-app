import Foundation

/// F3.7: turns pasted text into ingredient rows and steps, on the device (no AI).
enum RecipePaste {
    struct ParsedIngredient: Equatable {
        var quantity: Double?
        var unit: String
        var name: String
        var note: String
    }

    // MARK: Ingredients

    /// Unit words (any case, singular, plural or abbreviated) -> the editor's unit.
    static let unitAliases: [String: String] = {
        var m: [String: String] = [:]
        let groups: [String: [String]] = [
            "g": ["g", "gr", "gram", "grams", "gramme", "grammes"],
            "kg": ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms"],
            "ml": ["ml", "mls", "milliliter", "milliliters", "millilitre", "millilitres"],
            "l": ["l", "liter", "liters", "litre", "litres"],
            "oz": ["oz", "ozs", "ounce", "ounces"],
            "lb": ["lb", "lbs", "pound", "pounds"],
            "cup": ["cup", "cups", "c"],
            "tbsp": ["tbsp", "tbsps", "tbs", "tbl", "tablespoon", "tablespoons"],
            "tsp": ["tsp", "tsps", "teaspoon", "teaspoons"],
            "bunch": ["bunch", "bunches"],
            "pack": ["pack", "packs", "package", "packages", "packet", "packets"],
            "pinch": ["pinch", "pinches"],
            "dash": ["dash", "dashes"],
            "clove": ["clove", "cloves"],
            "can": ["can", "cans", "tin", "tins"],
            "slice": ["slice", "slices"],
            "sprig": ["sprig", "sprigs"],
            "handful": ["handful", "handfuls"],
            "stalk": ["stalk", "stalks"],
            "jar": ["jar", "jars"],
        ]
        for (unit, words) in groups { for w in words { m[w] = unit } }
        return m
    }()

    private static let fractions: [Character: Double] = [
        "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
    ]

    /// One ingredient per non-empty line; bullets and numbering are ignored.
    static func ingredients(_ text: String) -> [ParsedIngredient] {
        text.components(separatedBy: .newlines).compactMap(ingredient)
    }

    static func ingredient(_ raw: String) -> ParsedIngredient? {
        var line = stripBullet(raw)
        guard !line.isEmpty else { return nil }

        var quantity: Double?
        if let (q, rest) = leadingQuantity(line) { quantity = q; line = rest }

        var unit = "each"
        let words = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = words.first {
            let key = first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // A unit only follows an amount ("2 cups"), except words that are always units ("pinch of salt").
            if let u = unitAliases[key], quantity != nil || !["c", "l", "g"].contains(key), words.count > 1 {
                unit = u
                line = String(words[1])
            }
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.lowercased().hasPrefix("of ") { line = String(line.dropFirst(3)) }

        var name = line, note = ""
        if let comma = line.firstIndex(of: ",") {
            name = String(line[..<comma])
            note = String(line[line.index(after: comma)...])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        note = note.trimmingCharacters(in: .whitespaces)
        // "salt, to taste" / "pepper to taste"
        for phrase in ["to taste", "as needed"] {
            if note.lowercased() == phrase { note = ""; if quantity == nil { unit = "to taste" } }
            if name.lowercased().hasSuffix(" " + phrase) {
                name = String(name.dropLast(phrase.count + 1)).trimmingCharacters(in: .whitespaces)
                if quantity == nil { unit = "to taste" }
            }
        }
        if unit == "pinch" && quantity == nil { quantity = 1 }
        guard !name.isEmpty else { return nil }
        return ParsedIngredient(quantity: quantity, unit: unit, name: name, note: note)
    }

    /// "1 1/2 cups" -> (1.5, "cups"), "½ cup" -> 0.5, "1-2 onions" -> 2 (the higher), "1½" -> 1.5.
    static func leadingQuantity(_ line: String) -> (Double, String)? {
        var s = Substring(line)
        func skipSpaces() { while s.first == " " { s = s.dropFirst() } }

        func number() -> Double? {
            let start = s
            var digits = ""
            while let c = s.first, c.isNumber && c.isASCII || (c == "." && !digits.isEmpty && !digits.contains(".")) {
                digits.append(c); s = s.dropFirst()
            }
            if digits.hasSuffix(".") { digits.removeLast(); s = start.dropFirst(digits.count) }
            var value = Double(digits)
            // "1/2"
            if value != nil, s.first == "/" {
                let afterSlash = s.dropFirst()
                let den = afterSlash.prefix { $0.isNumber && $0.isASCII }
                if let d = Double(den), d > 0 {
                    value = value! / d
                    s = afterSlash.dropFirst(den.count)
                    return value
                }
            }
            if let c = s.first, let f = fractions[c] {             // "1½" or "½"
                s = s.dropFirst()
                return (value ?? 0) + f
            }
            if value == nil { s = start }
            return value
        }

        guard var q = number() else { return nil }
        // "1 1/2" or "1 ½": a whole number followed by a fraction
        if q == q.rounded() {
            let save = s
            skipSpaces()
            if let f = number(), f < 1 { q += f } else { s = save }
        }
        // Ranges: "1-2", "1 – 2", "1 to 2" -> the higher number
        let save = s
        skipSpaces()
        var isRange = false
        if let c = s.first, "-–—".contains(c) { s = s.dropFirst(); isRange = true }
        else if s.lowercased().hasPrefix("to ") { s = s.dropFirst(3); isRange = true }
        if isRange {
            skipSpaces()
            if let hi = number() { q = max(q, hi) } else { s = save }
        } else { s = save }

        guard q > 0, s.isEmpty || s.first == " " else { return nil }   // "3eggs" isn't an amount
        return (q, String(s).trimmingCharacters(in: .whitespaces))
    }

    /// "- 2 cups", "• 2 cups", "1. 2 cups", "2) flour" -> the line without its bullet or number.
    private static func stripBullet(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if let r = line.range(of: #"^(?:[-*•·–—▪◦]+|\d+[.)])\s+"#, options: .regularExpression) {
            line.removeSubrange(r)
        }
        // "[ ] flour" checklists
        if let r = line.range(of: #"^\[[ xX]?\]\s*"#, options: .regularExpression) { line.removeSubrange(r) }
        return line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Steps

    private static let numberedStep = #"^\s*(?:step\s*\d+\s*[.):\-–]?|\d+\s*[.)])\s*"#

    /// Splits at numbered lines ("1.", "2)", "Step 3"); without numbers, at blank lines; with
    /// neither, one step per line. Numbering and bullets are removed.
    static func steps(_ text: String) -> [String] {
        // Leading and trailing blank lines don't count as paragraph breaks.
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        let isNumbered = { (l: String) in l.range(of: numberedStep, options: [.regularExpression, .caseInsensitive]) != nil }

        var steps: [String] = []
        if lines.contains(where: isNumbered) {
            var current: String?
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if isNumbered(t) {
                    if let current { steps.append(current) }
                    current = t.replacingOccurrences(of: numberedStep, with: "", options: [.regularExpression, .caseInsensitive])
                } else if !t.isEmpty {
                    if let c = current { current = c.isEmpty ? t : c + " " + t }
                    else if !isHeading(t) { steps.append(stripBullet(t)) }   // text before step 1
                }
            }
            if let current { steps.append(current) }
        } else if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) &&
                    lines.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1 {
            var block: [String] = []
            for line in lines + [""] {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    if !block.isEmpty { steps.append(block.joined(separator: " ")); block = [] }
                } else { block.append(stripBullet(t)) }
            }
            if steps.count > 1, isHeading(steps[0]) { steps.removeFirst() }
        } else {
            steps = lines.map { stripBullet($0) }.filter { !$0.isEmpty }
            if steps.count > 1, isHeading(steps[0]) { steps.removeFirst() }
        }
        return steps.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "Method", "Instructions:", "Directions" -> a heading, not a step.
    private static func isHeading(_ t: String) -> Bool {
        let words = t.split(separator: " ")
        return t.hasSuffix(":") || (words.count <= 2 && !t.contains("."))
    }
}
