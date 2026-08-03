import Foundation

enum PathPolicyError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case forbiddenCharacter(String)
    case controlCharacter
    case trailingSpaceOrPeriod
    case dotPathSegment
    case reservedWindowsName(String)
    case nameTooLong(actual: Int, maximum: Int)
    case relativePathTooLong(actual: Int, maximum: Int)
    case absolutePath(String)
    case pathEscapesRoot(String)
    case nameCollision(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "이름을 비워둘 수 없습니다."
        case let .forbiddenCharacter(character):
            "Windows에서 사용할 수 없는 문자가 포함되어 있습니다: \(character)"
        case .controlCharacter:
            "제어 문자는 이름에 사용할 수 없습니다."
        case .trailingSpaceOrPeriod:
            "이름은 공백이나 마침표로 끝날 수 없습니다."
        case .dotPathSegment:
            ". 또는 ..은 이름으로 사용할 수 없습니다."
        case let .reservedWindowsName(name):
            "Windows 예약 이름은 사용할 수 없습니다: \(name)"
        case let .nameTooLong(actual, maximum):
            "이름이 너무 깁니다: \(actual)/\(maximum)"
        case let .relativePathTooLong(actual, maximum):
            "상대 경로가 너무 깁니다: \(actual)/\(maximum)"
        case let .absolutePath(path):
            "절대 경로를 사용할 수 없습니다: \(path)"
        case let .pathEscapesRoot(path):
            "작품 루트 밖의 경로를 사용할 수 없습니다: \(path)"
        case let .nameCollision(name):
            "대소문자 또는 Unicode 정규화 기준으로 같은 이름이 존재합니다: \(name)"
        }
    }
}

/// iPad에서 만든 이름을 Windows에서도 손실 없이 사용할 수 있게 제한한다.
struct PathPolicy: Sendable {
    struct Limits: Equatable, Sendable {
        /// Windows v2 확정 전 파일 시스템 안전 상한이다.
        var maximumNameUTF16Length = 255
        /// Windows v2 최종 저장 루트 확인 전의 임시 과다 경로 방지 상한이다.
        var maximumRelativePathUTF16Length = 1_024
    }

    let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// 저장·동기화 전에 이름을 확정한다. 끝 공백은 Windows 탐색기가 조용히
    /// 잘라내는 반면 앱이 그대로 두면 두 기기의 이름이 갈라지므로 여기서
    /// 없앤다. NFC로 맞추는 것도 같은 이유다. 잘라낸 뒤 남는 이름이 정책을
    /// 통과하지 못하면 그대로 던져서 파일 시스템과 서버를 건드리지 않는다.
    func sanitizedName(_ raw: String) throws -> String {
        let normalized = raw.precomposedStringWithCanonicalMapping
        var trimmed = normalized
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else {
            throw PathPolicyError.emptyName
        }
        try validateName(trimmed)
        return trimmed
    }

    /// 프로젝트명, 폴더명 또는 파일명 한 구성 요소를 검사한다.
    func validateName(_ name: String) throws {
        guard !name.isEmpty else {
            throw PathPolicyError.emptyName
        }
        guard name != ".", name != ".." else {
            throw PathPolicyError.dotPathSegment
        }

        let normalized = name.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")
        for scalar in normalized.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                throw PathPolicyError.controlCharacter
            }
            if forbidden.contains(scalar) {
                throw PathPolicyError.forbiddenCharacter(String(scalar))
            }
        }

        guard normalized.last != " ", normalized.last != "." else {
            throw PathPolicyError.trailingSpaceOrPeriod
        }

        let reservedCandidate = normalized
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            .uppercased(with: Locale(identifier: "en_US_POSIX")) ?? ""
        if Self.reservedWindowsNames.contains(reservedCandidate) {
            throw PathPolicyError.reservedWindowsName(reservedCandidate)
        }

        let length = normalized.utf16.count
        guard length <= limits.maximumNameUTF16Length else {
            throw PathPolicyError.nameTooLong(
                actual: length,
                maximum: limits.maximumNameUTF16Length
            )
        }
    }

    /// 비교 전 NFC 정규화와 대소문자 비구분을 적용한다.
    func collisionKey(for name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    func validateUniqueName(
        _ candidate: String,
        among existingNames: some Sequence<String>,
        allowingExactMatch: Bool = false
    ) throws {
        try validateName(candidate)
        let candidateKey = collisionKey(for: candidate)

        for existing in existingNames where collisionKey(for: existing) == candidateKey {
            if allowingExactMatch, existing == candidate {
                continue
            }
            throw PathPolicyError.nameCollision(existing)
        }
    }

    /// 프로젝트 루트를 기준으로 한 슬래시 구분 상대 경로를 검사한다.
    func validateRelativePath(_ relativePath: RelativeDocumentPath) throws {
        let rawPath = relativePath.rawValue
        guard !rawPath.isEmpty else {
            throw PathPolicyError.emptyName
        }
        guard !looksLikeAbsolutePath(rawPath) else {
            throw PathPolicyError.absolutePath(rawPath)
        }

        let length = rawPath.precomposedStringWithCanonicalMapping.utf16.count
        guard length <= limits.maximumRelativePathUTF16Length else {
            throw PathPolicyError.relativePathTooLong(
                actual: length,
                maximum: limits.maximumRelativePathUTF16Length
            )
        }

        let components = rawPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        for component in components {
            try validateName(String(component))
        }
    }

    /// 화면 이름을 실제 UTF-8 TXT 파일명으로 바꾼다.
    func textFileName(forDisplayName displayName: String) throws -> String {
        // 확장자를 붙이기 전에 정리한다. `이름 .txt`처럼 확장자 앞에 공백이
        // 남으면 Windows와 이름이 갈라진다.
        let normalized = displayName.precomposedStringWithCanonicalMapping
        let baseName: String
        if normalized.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .hasSuffix(".txt") {
            baseName = String(normalized.dropLast(4))
        } else {
            baseName = normalized
        }
        var trimmed = baseName
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else {
            throw PathPolicyError.emptyName
        }
        let storedName = trimmed + ".txt"
        try validateName(storedName)
        return storedName
    }

    /// 바인더에서만 마지막 .txt 확장자를 숨긴다.
    func binderDisplayName(forStoredName storedName: String) -> String {
        guard storedName.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .hasSuffix(".txt")
        else {
            return storedName
        }
        return String(storedName.dropLast(4))
    }

    private func looksLikeAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("\\") {
            return true
        }
        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 2 else {
            return false
        }
        return CharacterSet.letters.contains(scalars[0]) && scalars[1] == ":"
    }

    private static let reservedWindowsNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL", "CLOCK$"]
        for number in 1...9 {
            names.insert("COM\(number)")
            names.insert("LPT\(number)")
        }
        return names
    }()
}
