import Foundation

enum LinkExpiry: String, CaseIterable, Identifiable {
    case hour = "1h"
    case halfDay = "12h"
    case day = "24h"
    case threeDays = "72h"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: "1 час"
        case .halfDay: "12 часов"
        case .day: "24 часа"
        case .threeDays: "3 дня"
        }
    }
}

struct UploadError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum Uploader {
    private static let endpoint = URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!

    static func upload(_ png: Data, expiry: LinkExpiry, completion: @escaping (Result<URL, Error>) -> Void) {
        let boundary = "LidShot-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in [("reqtype", "fileupload"), ("time", expiry.rawValue)] {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(UUID().uuidString.prefix(8)).png\"\r\n")
        body.append("Content-Type: image/png\r\n\r\n")
        body.append(png)
        body.append("\r\n--\(boundary)--\r\n")

        URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failure(UploadError(message: "сервер ответил \(status)"))
            } else if let text = data.map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }),
                      text.hasPrefix("https://"), let url = URL(string: text) {
                result = .success(url)
            } else {
                result = .failure(UploadError(message: "неожиданный ответ сервера"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
