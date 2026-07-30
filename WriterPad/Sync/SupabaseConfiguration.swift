import Foundation

struct SupabasePublicConfiguration: Equatable, Sendable {
    let url: URL
    let publishableKey: String

    static func load(
        from values: [String: Any]
    ) -> Result<SupabasePublicConfiguration, SupabaseConfigurationError> {
        let rawURL = normalized(values[Keys.url])
        let rawKey = normalized(values[Keys.publishableKey])

        guard let rawURL, let rawKey else {
            return .failure(.missing)
        }
        guard
            let components = URLComponents(string: rawURL),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            let url = components.url
        else {
            return .failure(.invalidURL)
        }
        guard !containsForbiddenCredential(rawKey) else {
            return .failure(.forbiddenCredential)
        }

        return .success(
            SupabasePublicConfiguration(url: url, publishableKey: rawKey)
        )
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !trimmed.contains("$("),
            !trimmed.localizedCaseInsensitiveContains("example")
        else {
            return nil
        }
        return trimmed
    }

    private static func containsForbiddenCredential(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("sb_secret_")
            || lowercased.contains("service_role")
            || lowercased.contains("access_token")
            || lowercased.contains("refresh_token") {
            return true
        }

        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            return false
        }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let role = object["role"] as? String
        else {
            return false
        }
        return role == "service_role"
    }

    enum Keys {
        static let url = "WriterPadSupabaseURL"
        static let publishableKey = "WriterPadSupabasePublishableKey"
    }
}

enum SupabaseConfigurationError: String, Error, Equatable, Sendable {
    case missing
    case invalidURL
    case forbiddenCredential
}

enum SupabaseConfigurationState: Equatable, Sendable {
    case configured(SupabasePublicConfiguration)
    case unavailable(SupabaseConfigurationError)
}
