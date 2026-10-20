import AppKit
import Vision

enum TextRecognizer {
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages(for: request)
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let text = layout(request.results ?? [])
            DispatchQueue.main.async { completion(text) }
        }
    }

    static func recognize(_ image: NSImage, completion: @escaping (String) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion("")
            return
        }
        recognize(cgImage, completion: completion)
    }

    private static func languages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = Locale.preferredLanguages + ["ru-RU", "en-US"]
        var result: [String] = []
        for language in preferred {
            let code = language.split(separator: "-").first.map(String.init) ?? language
            let match = supported.first { $0 == language } ?? supported.first { $0.hasPrefix(code + "-") || $0 == code }
            if let match, !result.contains(match) {
                result.append(match)
            }
        }
        return result.isEmpty ? ["en-US"] : result
    }

    private static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        let items = observations.compactMap { observation -> (box: CGRect, text: String)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (observation.boundingBox, text)
        }
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for item in sorted {
            if let last = rows.last?.last,
               abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}

enum Clipboard {
    static var ownChangeCount = -1

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownChangeCount = pasteboard.changeCount
    }
}
