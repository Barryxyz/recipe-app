import UIKit

/// F4.4: a recipe as plain text (clipboard) or a PDF (share sheet). On the device only, so it
/// works offline. The PDF uses the system print layout: text stays selectable and long recipes
/// break across pages by themselves.
enum RecipeExport {
    struct Options {
        /// AI recipes (ai / edited / shared) end with the food-safety line; the user's own don't.
        var isAI = true
        var timesKnown: (prep: Bool, cook: Bool) = (true, true)
    }

    static let safetyLine = "AI-generated recipe: check that meat, poultry, fish and eggs reach safe temperatures."
    /// On every export (AI or not): the copy may reach someone with allergies the recipe wasn't made for.
    static let allergenLine = "Allergies: always read ingredient labels. Packaged foods (sauces, stocks, spice mixes) " +
        "can contain hidden allergens or traces. If an allergy is severe, double-check every ingredient before cooking."

    // MARK: Text

    static func text(_ r: RecipeAPI.Recipe, _ o: Options = .init()) -> String {
        var lines: [String] = ["\(r.title) (\(meta(r, o)))"]
        let description = r.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { lines += ["", description] }
        lines += ["", "Ingredients"] + r.ingredients.map { "- " + ingredient($0) }
        lines += ["", "Steps"] + r.steps.enumerated().map { "\($0.offset + 1). " + RecipeText.stepWithoutNumber($0.element) }
        if let m = macros(r) { lines += ["", m] }
        if o.isAI { lines.append(safetyLine) }
        lines.append(allergenLine)
        return lines.joined(separator: "\n")
    }

    /// "serves 2 · 30 min" (the time is left out when neither time is known).
    static func meta(_ r: RecipeAPI.Recipe, _ o: Options) -> String {
        var parts = ["serves \(r.servings)"]
        if o.timesKnown.prep || o.timesKnown.cook {
            parts.append(MacroFormat.minutes((o.timesKnown.prep ? r.prep_min : 0) + (o.timesKnown.cook ? r.cook_min : 0)))
        }
        return parts.joined(separator: " · ")
    }

    /// "300 g chicken thighs, roughly chopped", "salt, to taste", "lime (optional)".
    static func ingredient(_ i: RecipeAPI.Ingredient) -> String {
        var s: String
        if i.unit == "to taste" {
            s = "\(i.name), to taste"
        } else if i.quantity != nil {
            let unit = i.unit == "each" ? nil : i.unit
            s = "\(MacroFormat.amount(i.quantity, unit: unit)) \(i.name)"
        } else {
            s = i.name
        }
        if let note = i.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty, i.unit != "to taste" { s += ", \(note)" }
        if i.is_optional { s += " (optional)" }
        return s
    }

    /// "Per serving: ≈520 kcal · 38 g protein · 41 g carbs · 22 g fat", or nil before nutrition exists.
    static func macros(_ r: RecipeAPI.Recipe) -> String? {
        let m = r.macros_per_serving
        guard m.kcal > 0 else { return nil }
        let approx = m.estimated ? "≈" : ""
        return "Per serving: \(approx)\(Int(m.kcal.rounded())) kcal · \(Int(m.protein_g.rounded())) g protein · " +
            "\(Int(m.carbs_g.rounded())) g carbs · \(Int(m.fat_g.rounded())) g fat"
    }

    // MARK: PDF

    /// Letter in the US and Canada, A4 elsewhere (points).
    static var paperSize: CGSize {
        ["US", "CA"].contains(Locale.current.region?.identifier ?? "") ? CGSize(width: 612, height: 792)
            : CGSize(width: 595.2, height: 841.8)
    }

    static func html(_ r: RecipeAPI.Recipe, _ o: Options = .init()) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let description = r.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var h = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 12pt; color: #111; line-height: 1.4; }
        h1 { font-size: 22pt; margin: 0 0 4pt 0; }
        .meta { color: #555; margin-bottom: 10pt; }
        h2 { font-size: 14pt; margin: 16pt 0 6pt 0; border-bottom: 0.5pt solid #bbb; padding-bottom: 2pt; }
        ul { padding-left: 16pt; margin: 0; } li { margin: 2pt 0; }
        ol { padding-left: 20pt; margin: 0; } ol li { margin: 0 0 7pt 0; page-break-inside: avoid; }
        .macros { margin-top: 14pt; } .note { color: #555; font-size: 10pt; margin-top: 8pt; }
        </style></head><body>
        <h1>\(esc(r.title))</h1>
        <div class="meta">\(esc(meta(r, o).prefix(1).uppercased() + meta(r, o).dropFirst()))</div>
        """
        if !description.isEmpty { h += "<p>\(esc(description))</p>" }
        h += "<h2>Ingredients</h2><ul>" + r.ingredients.map { "<li>\(esc(ingredient($0)))</li>" }.joined() + "</ul>"
        h += "<h2>Steps</h2><ol>" + r.steps.map { "<li>\(esc(RecipeText.stepWithoutNumber($0)))</li>" }.joined() + "</ol>"
        if let m = macros(r) { h += "<div class=\"macros\">\(esc(m))</div>" }
        if o.isAI { h += "<div class=\"note\">\(esc(safetyLine))</div>" }
        h += "<div class=\"note\">\(esc(allergenLine))</div>"
        return h + "</body></html>"
    }

    /// Renders the PDF (main thread: it uses the print system).
    @MainActor
    static func pdfData(_ r: RecipeAPI.Recipe, _ o: Options = .init()) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html(r, o))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let paper = CGRect(origin: .zero, size: paperSize)
        renderer.setValue(paper, forKey: "paperRect")
        renderer.setValue(paper.insetBy(dx: 54, dy: 54), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [kCGPDFContextTitle as String: r.title,
                                                      kCGPDFContextCreator as String: "Fridge"])
        for page in 0..<max(1, renderer.numberOfPages) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// Writes the PDF to a temporary folder (named after the recipe); delete it when done.
    @MainActor
    static func pdfFile(_ r: RecipeAPI.Recipe, _ o: Options = .init()) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = r.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Recipe" : String(safe.prefix(80))).pdf")
        try pdfData(r, o).write(to: url, options: .atomic)
        return url
    }
}
