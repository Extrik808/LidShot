import Foundation
import FoundationModels
import NaturalLanguage

enum LanguageDetector {
    static func detect(_ text: String) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        let latin = letters.filter { $0.isASCII }.count

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = TargetLanguage.all.map { NLLanguage($0.id) } + [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        let best = recognizer.languageHypotheses(withMaximum: 1).first

        if cyrillic * 2 > letters.count {
            if let best, best.key == .ukrainian, best.value > 0.8 { return "uk" }
            return "ru"
        }
        let words = text.split { $0.isWhitespace || $0.isPunctuation }.count
        if latin * 2 > letters.count, words < 4 || (best?.value ?? 0) < 0.75 {
            return "en"
        }
        guard let best else { return nil }
        if best.key == .simplifiedChinese || best.key == .traditionalChinese { return "zh-Hans" }
        return TargetLanguage.find(best.key.rawValue)?.id ?? best.key.rawValue
    }
}

enum EnglishStyle: String, CaseIterable {
    case literal, casual, business

    var title: String {
        switch self {
        case .literal: "Как перевёл переводчик"
        case .casual: "Разговорный"
        case .business: "Деловой"
        }
    }

    static var current: EnglishStyle {
        get { EnglishStyle(rawValue: UserDefaults.standard.string(forKey: "englishStyle") ?? "") ?? .casual }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "englishStyle") }
    }

    static var modelAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    static var modelStatus: String {
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Apple Intelligence готов"
            case .unavailable(.appleIntelligenceNotEnabled): return "Включите Apple Intelligence в Системных настройках"
            case .unavailable(.modelNotReady): return "Модель Apple Intelligence ещё загружается"
            case .unavailable(.deviceNotEligible): return "Этот Mac не поддерживает Apple Intelligence"
            default: return "Apple Intelligence недоступен"
            }
        }
        return "Нужна macOS 26 и Apple Intelligence"
    }

    var canPolish: Bool {
        self != .literal && Self.modelAvailable
    }

    private var instructions: String {
        let tone = switch self {
        case .business: "clear, polite, professional English, the way a native speaker writes a work email"
        default: "natural, casual, conversational English, the way a native speaker writes in a work chat like Slack"
        }
        return """
        You rewrite a machine translation into \(tone). \
        The user gives the machine translation, and the original text for reference. \
        Keep the exact meaning, names, numbers, code, links, mentions and emoji. Do not add greetings, \
        explanations or anything that is not in the original. Keep it about the same length. \
        Reply with the rewritten English text only.
        """
    }

    func polish(_ english: String, original: String) async -> String {
        guard canPolish else { return english }
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let prompt = "Original:\n\(original)\n\nMachine translation:\n\(english)"
                let reply = try await session.respond(to: prompt)
                let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? english : text
            } catch {
                return english
            }
        }
        return english
    }
}
