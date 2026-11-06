import Foundation

enum SensitiveKind: String, CaseIterable, Identifiable {
    case email, phone, identity, payment, credential
    var id: String { rawValue }
    var title: String { switch self { case .email: L10n.text("邮箱"); case .phone: L10n.text("电话"); case .identity: L10n.text("身份证"); case .payment: L10n.text("银行卡"); case .credential: L10n.text("密钥") } }
}

enum SensitiveContent {
    private static let patterns: [(SensitiveKind, NSRegularExpression)] = [
        (.email, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#),
        // OCR can insert horizontal spaces around @ and domain separators.
        // Flag the original row for review; never join lines or rewrite text.
        (.email, #"[A-Z0-9._%+-]+[\p{Zs}\t]*@[\p{Zs}\t]*[A-Z0-9-]+(?:[\p{Zs}\t]*\.[\p{Zs}\t]*[A-Z0-9-]+)*[\p{Zs}\t]*\.[\p{Zs}\t]*[A-Z]{2,}"#),
        (.phone, #"(?<!\d)(?:\+?86[ -]?)?1[3-9]\d{9}(?!\d)|(?<!\w)\+[1-9](?:[ -]?\d){7,14}(?!\d)"#),
        (.identity, #"(?<!\d)[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9X](?!\w)"#),
        (.payment, #"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#),
        (.credential, #"(?<![A-Z0-9])(?:sk-[A-Z0-9_-]{16,}|ghp_[A-Z0-9]{20,}|github_pat_[A-Z0-9_]{20,}|AKIA[A-Z0-9]{16})(?![A-Z0-9])"#)
    ].compactMap { kind, pattern in (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (kind, $0) } }

    static func kinds(in text: String) -> Set<SensitiveKind> {
        var result = Set<SensitiveKind>()
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (kind, regex) in patterns {
            for match in regex.matches(in: text, range: range) {
                if kind == .payment {
                    guard let r = Range(match.range, in: text), validCard(String(text[r])) else { continue }
                }
                result.insert(kind); break
            }
        }
        return result
    }
    static func validCard(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            let n = item.offset % 2 == 1 ? item.element * 2 : item.element
            return total + (n > 9 ? n - 9 : n)
        }
        return sum % 10 == 0
    }
}
