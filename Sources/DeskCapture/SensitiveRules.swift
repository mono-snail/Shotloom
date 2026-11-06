import Foundation
import Combine

enum SensitiveRuleMode: String, Codable, CaseIterable, Identifiable {
    case literal, prefix, boundedPattern
    var id: String { rawValue }
    var title: String { switch self { case .literal: L10n.text("包含文字"); case .prefix: L10n.text("行前缀"); case .boundedPattern: L10n.text("受限正则") } }
}
enum SensitiveRuleScope: String, Codable, CaseIterable, Identifiable {
    case all, images, text, captions
    var id: String { rawValue }
    var title: String { switch self { case .all: L10n.text("全部"); case .images: L10n.text("图片"); case .text: L10n.text("文本"); case .captions: L10n.text("字幕") } }
}
struct SensitiveRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var title = L10n.text("自定义字段")
    var pattern = L10n.text("订单号")
    var mode = SensitiveRuleMode.literal
    var scope = SensitiveRuleScope.images
    var caseSensitive = false
    var enabled = true
}
struct SensitiveReviewCandidate: Identifiable {
    var id: UUID { line.id }
    let line: OCRLine
    let kinds: Set<SensitiveKind>
    let ruleNames: [String]
    var reason: String { (SensitiveKind.allCases.filter(kinds.contains).map(\.title)+ruleNames).joined(separator:L10n.text(" · ")) }
}

enum SafeSensitivePattern {
    /// No groups, alternation, backreferences or unbounded quantifiers. At most
    /// one bounded variable repeat; all repeats are <=64 and expansion <=512.
    static func cost(_ pattern: String) throws -> Int {
        let chars=Array(pattern)
        guard !chars.isEmpty, chars.count<=256,pattern.utf8.count<=1024 else { throw CaptureError.message(L10n.text("规则模式需为1–256字且不超过1KB。")) }
        var index=0,atoms=0,expanded=0,lastAtom=false,lastCost=0,variable=0,variableMax=1
        func invalid() -> CaptureError { .message(L10n.text("受限正则不支持分组、分支、回溯引用或无限重复；可用字符组和{n}、{n,m}（1–64，仅一个变长重复）。")) }
        while index<chars.count {
            let c=chars[index]
            if c == "\\" {
                index += 1;guard index<chars.count else { throw invalid() }
                let escaped=chars[index]
                guard "dDsSwW\\.[]{}()+*?^$|-@/".contains(escaped) else { throw invalid() }
                atoms+=1;expanded+=1;lastAtom=true;lastCost=1;index+=1
            } else if c == "[" {
                index+=1;var count=0,closed=false
                while index<chars.count {
                    if chars[index] == "]" { closed=true;index+=1;break }
                    if chars[index] == "[" { throw invalid() }
                    if chars[index] == "\\" { index+=1;guard index<chars.count,"dDsSwW\\.-]".contains(chars[index]) else { throw invalid() } }
                    count+=1;index+=1
                }
                guard closed,count>0 else { throw invalid() }
                atoms+=1;expanded+=1;lastAtom=true;lastCost=1
            } else if c == "{" {
                guard lastAtom else { throw invalid() };index+=1;var body=""
                while index<chars.count,chars[index] != "}" { body.append(chars[index]);index+=1 }
                guard index<chars.count else { throw invalid() };index+=1
                let numbers=body.split(separator:",",omittingEmptySubsequences:false)
                guard (1...2).contains(numbers.count),numbers.allSatisfy({!$0.isEmpty && $0.allSatisfy(\.isNumber)}),
                      let minimum=Int(numbers[0]),let maximum=Int(numbers.last!),minimum>=1,maximum>=minimum,maximum<=64 else { throw invalid() }
                if minimum != maximum { variable+=1;variableMax=maximum;guard variable<=1 else { throw invalid() } }
                expanded+=lastCost*(maximum-1);lastAtom=false
            } else if "()*+?|}".contains(c) { throw invalid() }
            else if c == "^" || c == "$" { lastAtom=false;index+=1 }
            else { guard !c.isNewline else { throw invalid() };atoms+=1;expanded+=1;lastAtom=true;lastCost=1;index+=1 }
            guard expanded<=512 else { throw invalid() }
        }
        guard atoms>0 else { throw invalid() }
        _ = try NSRegularExpression(pattern:pattern)
        return max(1,expanded*variableMax)
    }
}

enum SensitiveRuleEvaluation {
    private struct Compiled {
        let rule: SensitiveRule
        let regex: NSRegularExpression?
        let cost: Int
        func matches(_ text: String) -> Bool {
            if let regex { return regex.firstMatch(in:text,range:NSRange(text.startIndex..<text.endIndex,in:text)) != nil }
            var options:String.CompareOptions=rule.caseSensitive ? [] : [.caseInsensitive]
            if rule.mode == .prefix { options.insert(.anchored) }
            return text.range(of:rule.pattern,options:options) != nil
        }
    }
    static func validate(_ rules: [SensitiveRule]) throws {
        guard rules.count<=32,Set(rules.map(\.id)).count==rules.count else { throw CaptureError.message(L10n.text("最多32条规则，规则标识不能重复。")) }
        for rule in rules { _ = try compile(rule) }
    }
    private static func compile(_ rule: SensitiveRule) throws -> Compiled {
        guard !rule.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,rule.title.count<=40,
              !rule.pattern.isEmpty,rule.pattern.count<=256,rule.pattern.utf8.count<=1024 else {
            throw CaptureError.message(L10n.text("规则名称需1–40字，模式需1–256字且不超过1KB。"))
        }
        if rule.mode == .boundedPattern {
            let cost=try SafeSensitivePattern.cost(rule.pattern)
            return .init(rule:rule,regex:try NSRegularExpression(pattern:rule.pattern,options:rule.caseSensitive ? [] : [.caseInsensitive]),cost:cost)
        }
        return .init(rule:rule,regex:nil,cost:1)
    }
    static func classify(_ lines: [OCRLine], kinds: Set<SensitiveKind>, rules: [SensitiveRule], scope: SensitiveRuleScope) throws -> [SensitiveReviewCandidate] {
        try validate(rules)
        guard lines.count<=5000 else { throw CaptureError.message(L10n.text("一次最多复核5000行，请分区处理。")) }
        let active=try rules.filter{$0.enabled && ($0.scope == .all || $0.scope == scope)}.map(compile)
        let characters=lines.reduce(0){$0+$1.text.utf16.count+$1.alternatives.reduce(0){$0+$1.utf16.count}}
        guard characters<=1_000_000,Double(characters)*Double(active.reduce(0){$0+$1.cost})<=50_000_000,
              lines.allSatisfy({$0.text.utf16.count<=4096 && $0.alternatives.allSatisfy{$0.utf16.count<=4096}}) else {
            throw CaptureError.message(L10n.text("文本或规则计算超过预算，尚未完成检查，请减少规则或分区复核。"))
        }
        return try lines.compactMap { line in
            try Task.checkCancellation()
            let values=[line.text]+line.alternatives
            let builtin=values.reduce(into:Set<SensitiveKind>()){ $0.formUnion(SensitiveContent.kinds(in:$1).intersection(kinds)) }
            let names=active.filter { rule in values.contains(where:rule.matches) }.map{$0.rule.title}
            return builtin.isEmpty && names.isEmpty ? nil : .init(line:line,kinds:builtin,ruleNames:names)
        }
    }
}

@MainActor
final class SensitiveRuleStore: ObservableObject {
    @Published private(set) var rules: [SensitiveRule]=[]
    @Published private(set) var revision=UUID()
    @Published private(set) var loadError: String?
    private let defaults: UserDefaults
    private let key="sensitiveCustomRules.v1"
    init(defaults: UserDefaults = AppPreferences.standard) {
        self.defaults=defaults
        guard let data=defaults.data(forKey:key) else { return }
        do {
            guard data.count<=64_000 else { throw CaptureError.message(L10n.text("规则配置超过64KB。")) }
            let decoded=try JSONDecoder().decode([SensitiveRule].self,from:data)
            try SensitiveRuleEvaluation.validate(decoded);rules=decoded
        } catch { loadError=L10n.text("自定义规则未加载：\(error.localizedDescription) 原配置已保留。") }
    }
    func save(_ value: [SensitiveRule]) async throws {
        let task=Task.detached(priority:.userInitiated) { () throws -> Data in
            try SensitiveRuleEvaluation.validate(value);return try JSONEncoder().encode(value)
        }
        let data=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        try Task.checkCancellation()
        guard data.count<=64_000 else { throw CaptureError.message(L10n.text("规则配置超过64KB。")) }
        defaults.set(data,forKey:key);rules=value;revision=UUID();loadError=nil
    }
}
