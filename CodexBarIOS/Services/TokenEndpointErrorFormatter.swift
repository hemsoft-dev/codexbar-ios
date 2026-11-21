import Foundation

enum TokenEndpointErrorFormatter {
    private static let maximumErrorCodeLength = 64
    private static let allowedErrorCodeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    )

    static func message(statusCode: Int, body: Data) -> String {
        let statusMessage = "HTTP \(statusCode)"
        guard let errorCode = oauthErrorCode(from: body) else {
            return statusMessage
        }
        return "\(statusMessage) (\(errorCode))"
    }

    static func message(errorCode: String) -> String {
        safeOAuthErrorCode(errorCode) ?? "Token endpoint rejected the request."
    }

    static func oauthErrorCode(from body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let dictionary = object as? [String: Any],
            let errorCode = dictionary["error"] as? String
        else {
            return nil
        }
        return safeOAuthErrorCode(errorCode)
    }

    private static func safeOAuthErrorCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= maximumErrorCodeLength,
            trimmed.unicodeScalars.allSatisfy(allowedErrorCodeCharacters.contains)
        else {
            return nil
        }
        return trimmed
    }
}
