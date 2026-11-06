import Foundation

enum OCRLanguageReview {
    static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value) || (0x20000...0x2fa1f).contains($0.value) }.count
    }
    static func merge(automatic: [OCRLine], explicit: [OCRLine]) -> [OCRLine] {
        automatic.map { original in
            let candidates = explicit.filter { line in
                let intersection = line.bounds.intersection(original.bounds)
                guard !intersection.isNull else { return false }
                let area = intersection.width * intersection.height
                let union = line.bounds.width * line.bounds.height + original.bounds.width * original.bounds.height - area
                // A candidate for only one column/half a row must never replace
                // a full row and silently discard its trailing text or numbers.
                return union > 0 && area / union >= 0.8
                    && intersection.width >= max(line.bounds.width, original.bounds.width) * 0.95
                    && hanCount(line.text) >= hanCount(original.text) + 2
            }
            guard let candidate = candidates.max(by: { hanCount($0.text) < hanCount($1.text) }) else { return original }
            // The two language paths have different confidence scales (a correct
            // Chinese result can score 0.5 while the Latin misreading scores 1).
            // Retain both outputs and require review instead of comparing scores.
            var selected = candidate.confidence.isFinite && candidate.confidence > 0 ? candidate : original
            selected.alternatives = [selected.text == candidate.text ? original.text : candidate.text]
            return selected
        }
    }
}
