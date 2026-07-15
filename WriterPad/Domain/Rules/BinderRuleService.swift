import Foundation

enum BinderRuleDecision: Equatable, Sendable {
    case allowed
    case denied(BinderRuleViolation)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var userReason: String? {
        guard case let .denied(violation) = self else { return nil }
        return violation.userMessage
    }
}

enum BinderRuleViolation: Equatable, Sendable {
    case invalidWindowsName(String)
    case duplicateNormalizedName(String)
    case manuscriptAcceptsVolumeFoldersOnly
    case invalidVolumeName
    case volumeAcceptsChapterTextsOnly
    case invalidChapterName
    case duplicateChapterNumber(Int)
    case volumeNameLocked
    case chapterPrefixLocked(String)
    case manuscriptRootLocked
    case manuscriptCannotLeave
    case externalItemCannotEnterManuscript
    case invalidManuscriptDestination
    case manuscriptUsesNaturalOrder

    var userMessage: String {
        switch self {
        case let .invalidWindowsName(reason):
            reason
        case let .duplicateNormalizedName(name):
            "대소문자 또는 Unicode 정규화 기준으로 같은 이름이 존재합니다: \(name)"
        case .manuscriptAcceptsVolumeFoldersOnly:
            "원고 바로 아래에는 1권 같은 권 폴더만 만들 수 있습니다."
        case .invalidVolumeName:
            "권 이름은 앞자리 0이 없는 양의 정수와 ‘권’으로 구성해야 합니다. 예: 1권"
        case .volumeAcceptsChapterTextsOnly:
            "권 폴더 안에는 001화.txt 같은 원고 TXT만 만들 수 있습니다."
        case .invalidChapterName:
            "화 파일은 001화.txt 형식이어야 하며 1,000화부터는 1000화.txt처럼 표시합니다."
        case let .duplicateChapterNumber(number):
            "같은 화 번호를 중복해서 만들 수 없습니다: \(number)화"
        case .volumeNameLocked:
            "권 이름은 변경할 수 없습니다."
        case let .chapterPrefixLocked(prefix):
            "화 이름의 ‘\(prefix)’ 접두사는 변경할 수 없습니다."
        case .manuscriptRootLocked:
            "원고 최상위 항목은 이동하거나 이름을 변경할 수 없습니다."
        case .manuscriptCannotLeave:
            "원고 안의 항목을 다른 최상위 카테고리로 이동할 수 없습니다."
        case .externalItemCannotEnterManuscript:
            "원고 밖의 문서나 폴더를 원고 안으로 이동할 수 없습니다."
        case .invalidManuscriptDestination:
            "이 위치로 이동하면 원고의 권·화 구조가 깨집니다."
        case .manuscriptUsesNaturalOrder:
            "원고 내부 순서는 권·화 번호의 자연 정렬로 고정됩니다."
        }
    }
}

struct BinderCreationRuleRequest: Equatable, Sendable {
    let parentPath: RelativeDocumentPath
    let kind: DocumentKind
    let storedName: String
    var existingSiblingNames: [String] = []
    var existingManuscriptChapterPaths: [RelativeDocumentPath] = []
}

struct BinderRenameRuleRequest: Equatable, Sendable {
    let sourcePath: RelativeDocumentPath
    let kind: DocumentKind
    let proposedStoredName: String
    var existingSiblingNames: [String] = []
}

struct BinderMoveRuleRequest: Equatable, Sendable {
    let sourcePath: RelativeDocumentPath
    let kind: DocumentKind
    let destinationFolderPath: RelativeDocumentPath
    var existingDestinationNames: [String] = []
    var existingManuscriptChapterPaths: [RelativeDocumentPath] = []
}

struct ManuscriptChapterIdentity: Equatable, Sendable {
    let number: Int
    let protectedPrefix: String
    let titleSuffix: String
}

struct BinderRuleService: Sendable {
    private enum ManuscriptLocation: Equatable {
        case outside
        case root
        case volume(Int)
        case chapter(volume: Int, identity: ManuscriptChapterIdentity)
        case invalid
    }

    private let pathPolicy: PathPolicy

    init(pathPolicy: PathPolicy = PathPolicy()) {
        self.pathPolicy = pathPolicy
    }

    func evaluateCreation(_ request: BinderCreationRuleRequest) -> BinderRuleDecision {
        if let denial = nameDenial(
            request.storedName,
            existingNames: request.existingSiblingNames
        ) {
            return denial
        }

        switch manuscriptLocation(of: request.parentPath) {
        case .outside:
            return .allowed
        case .root:
            guard request.kind == .folder else {
                return .denied(.manuscriptAcceptsVolumeFoldersOnly)
            }
            guard volumeNumber(fromStoredName: request.storedName) != nil else {
                return .denied(.invalidVolumeName)
            }
            return .allowed
        case .volume:
            guard request.kind == .text else {
                return .denied(.volumeAcceptsChapterTextsOnly)
            }
            guard let identity = canonicalChapterIdentity(
                fromStoredName: request.storedName
            ) else {
                return .denied(.invalidChapterName)
            }
            if containsChapter(
                number: identity.number,
                in: request.existingManuscriptChapterPaths,
                excluding: nil
            ) {
                return .denied(.duplicateChapterNumber(identity.number))
            }
            return .allowed
        case .chapter, .invalid:
            return .denied(.invalidManuscriptDestination)
        }
    }

    func evaluateRename(_ request: BinderRenameRuleRequest) -> BinderRuleDecision {
        let oldName = storedName(of: request.sourcePath)
        let siblingNames = removingOneExactMatch(oldName, from: request.existingSiblingNames)
        let location = manuscriptLocation(of: request.sourcePath)
        if oldName == request.proposedStoredName {
            return nameDenial(request.proposedStoredName, existingNames: siblingNames)
                ?? .allowed
        }
        switch location {
        case .root:
            return .denied(.manuscriptRootLocked)
        case .volume:
            return .denied(.volumeNameLocked)
        default:
            break
        }
        if let denial = basicNameDenial(request.proposedStoredName) {
            return denial
        }

        switch location {
        case .outside:
            return nameDenial(request.proposedStoredName, existingNames: siblingNames)
                ?? .allowed
        case let .chapter(_, identity):
            guard request.kind == .text,
                  let proposed = titledChapterIdentity(
                    fromStoredName: request.proposedStoredName
                  )
            else {
                return .denied(.invalidChapterName)
            }
            guard proposed.protectedPrefix == identity.protectedPrefix else {
                return .denied(.chapterPrefixLocked(identity.protectedPrefix))
            }
            return nameDenial(request.proposedStoredName, existingNames: siblingNames)
                ?? .allowed
        case .invalid:
            return .denied(.invalidManuscriptDestination)
        case .root, .volume:
            return .denied(.invalidManuscriptDestination)
        }
    }

    func evaluateMove(_ request: BinderMoveRuleRequest) -> BinderRuleDecision {
        evaluateRelocation(request)
    }

    func evaluateDrop(_ request: BinderMoveRuleRequest) -> BinderRuleDecision {
        evaluateRelocation(request)
    }

    /// 휴지통 이동은 일반 위치 이동과 다른 삭제 명령이다.
    /// 원고 권·화도 원래 경로를 보존하는 조건으로 휴지통에 놓을 수 있다.
    func evaluateTrash(
        sourcePath: RelativeDocumentPath,
        kind: DocumentKind,
        existingTrashNames: [String]
    ) -> BinderRuleDecision {
        switch manuscriptLocation(of: sourcePath) {
        case .root:
            return .denied(.manuscriptRootLocked)
        case .invalid:
            return .denied(.invalidManuscriptDestination)
        case .outside, .volume, .chapter:
            return nameDenial(
                storedName(of: sourcePath),
                existingNames: existingTrashNames
            ) ?? .allowed
        }
    }

    func evaluateReorder(
        itemPath: RelativeDocumentPath,
        proposedIndex: Int
    ) -> BinderRuleDecision {
        switch manuscriptLocation(of: itemPath) {
        case .outside:
            return .allowed
        case .root:
            return proposedIndex == 0 ? .allowed : .denied(.manuscriptRootLocked)
        case .volume, .chapter, .invalid:
            return .denied(.manuscriptUsesNaturalOrder)
        }
    }

    func volumeNumber(fromStoredName name: String) -> Int? {
        guard name.hasSuffix("권") else { return nil }
        let digits = String(name.dropLast())
        guard isASCIIInteger(digits), digits.first != "0",
              let number = Int(digits), number > 0,
              String(number) == digits
        else {
            return nil
        }
        return number
    }

    func canonicalChapterIdentity(
        fromStoredName name: String
    ) -> ManuscriptChapterIdentity? {
        guard let identity = titledChapterIdentity(fromStoredName: name),
              identity.titleSuffix.isEmpty
        else {
            return nil
        }
        return identity
    }

    func titledChapterIdentity(
        fromStoredName name: String
    ) -> ManuscriptChapterIdentity? {
        guard name.hasSuffix(".txt") else { return nil }
        let body = String(name.dropLast(4))
        var digits = ""
        var remainder = body[...]
        while let scalar = remainder.unicodeScalars.first,
              (48...57).contains(scalar.value) {
            digits.unicodeScalars.append(scalar)
            remainder = remainder.dropFirst()
        }
        guard remainder.hasPrefix("화"), digits.count >= 3,
              let number = Int(digits), number > 0
        else {
            return nil
        }
        let canonicalDigits = number < 1_000
            ? String(format: "%03d", number)
            : String(number)
        guard digits == canonicalDigits else { return nil }
        return ManuscriptChapterIdentity(
            number: number,
            protectedPrefix: digits + "화",
            titleSuffix: String(remainder.dropFirst())
        )
    }

    func usesManuscriptNaturalOrder(in parentPath: RelativeDocumentPath) -> Bool {
        switch manuscriptLocation(of: parentPath) {
        case .root, .volume:
            true
        case .outside, .chapter, .invalid:
            false
        }
    }

    func manuscriptItemPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let leftNumber = volumeNumber(fromStoredName: lhs)
            ?? titledChapterIdentity(fromStoredName: lhs)?.number
        let rightNumber = volumeNumber(fromStoredName: rhs)
            ?? titledChapterIdentity(fromStoredName: rhs)?.number
        switch (leftNumber, rightNumber) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func evaluateRelocation(_ request: BinderMoveRuleRequest) -> BinderRuleDecision {
        let source = manuscriptLocation(of: request.sourcePath)
        let destination = manuscriptLocation(of: request.destinationFolderPath)
        let sourceInside = source != .outside
        let destinationInside = destination != .outside

        if case .root = source { return .denied(.manuscriptRootLocked) }
        if sourceInside, !destinationInside { return .denied(.manuscriptCannotLeave) }
        if !sourceInside, destinationInside {
            return .denied(.externalItemCannotEnterManuscript)
        }

        let name = storedName(of: request.sourcePath)
        let sourceParent = parentPath(of: request.sourcePath)
        let destinationNames = sourceParent == request.destinationFolderPath
            ? removingOneExactMatch(name, from: request.existingDestinationNames)
            : request.existingDestinationNames
        if let denial = nameDenial(name, existingNames: destinationNames) {
            return denial
        }

        if !sourceInside { return .allowed }
        switch (source, destination) {
        case (.volume, .root):
            return request.kind == .folder
                ? .allowed
                : .denied(.invalidManuscriptDestination)
        case let (.chapter(_, identity), .volume):
            guard request.kind == .text else {
                return .denied(.invalidManuscriptDestination)
            }
            if containsChapter(
                number: identity.number,
                in: request.existingManuscriptChapterPaths,
                excluding: request.sourcePath
            ) {
                return .denied(.duplicateChapterNumber(identity.number))
            }
            return .allowed
        default:
            return .denied(.invalidManuscriptDestination)
        }
    }

    private func manuscriptLocation(
        of path: RelativeDocumentPath
    ) -> ManuscriptLocation {
        let components = path.rawValue.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count >= 2,
              pathPolicy.collisionKey(for: components[0])
                == pathPolicy.collisionKey(for: "메인"),
              pathPolicy.collisionKey(for: components[1])
                == pathPolicy.collisionKey(for: "원고")
        else {
            return .outside
        }
        if components.count == 2 { return .root }
        guard let volume = volumeNumber(fromStoredName: components[2]) else {
            return .invalid
        }
        if components.count == 3 { return .volume(volume) }
        guard components.count == 4,
              let chapter = titledChapterIdentity(fromStoredName: components[3])
        else {
            return .invalid
        }
        return .chapter(volume: volume, identity: chapter)
    }

    private func nameDenial(
        _ name: String,
        existingNames: [String]
    ) -> BinderRuleDecision? {
        do {
            try pathPolicy.validateUniqueName(name, among: existingNames)
            return nil
        } catch let error as PathPolicyError {
            if case let .nameCollision(existing) = error {
                return .denied(.duplicateNormalizedName(existing))
            }
            return .denied(.invalidWindowsName(error.localizedDescription))
        } catch {
            return .denied(.invalidWindowsName(error.localizedDescription))
        }
    }

    private func basicNameDenial(_ name: String) -> BinderRuleDecision? {
        do {
            try pathPolicy.validateName(name)
            return nil
        } catch {
            return .denied(.invalidWindowsName(error.localizedDescription))
        }
    }

    private func containsChapter(
        number: Int,
        in paths: [RelativeDocumentPath],
        excluding excludedPath: RelativeDocumentPath?
    ) -> Bool {
        let excludedKey = excludedPath.map(normalizedPathKey)
        return paths.contains { path in
            if let excludedKey, normalizedPathKey(path) == excludedKey { return false }
            return titledChapterIdentity(fromStoredName: storedName(of: path))?.number == number
        }
    }

    private func normalizedPathKey(_ path: RelativeDocumentPath) -> String {
        path.rawValue.split(separator: "/")
            .map { pathPolicy.collisionKey(for: String($0)) }
            .joined(separator: "/")
    }

    private func storedName(of path: RelativeDocumentPath) -> String {
        path.rawValue.split(separator: "/").last.map(String.init) ?? ""
    }

    private func parentPath(of path: RelativeDocumentPath) -> RelativeDocumentPath {
        RelativeDocumentPath(
            rawValue: path.rawValue.split(separator: "/").dropLast().joined(separator: "/")
        )
    }

    private func removingOneExactMatch(_ name: String, from names: [String]) -> [String] {
        var result = names
        if let index = result.firstIndex(of: name) { result.remove(at: index) }
        return result
    }

    private func isASCIIInteger(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }
}
