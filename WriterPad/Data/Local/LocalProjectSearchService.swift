import Foundation

/// 인덱스를 만들지 않고 작품의 현재 TXT 스냅샷을 직접 읽어 검색한다.
struct LocalProjectSearchService: Searching {
    private let documentRepository: any DocumentRepository
    private let documentStore: any LocalDocumentStoring

    init(
        documentRepository: any DocumentRepository,
        documentStore: any LocalDocumentStoring
    ) {
        self.documentRepository = documentRepository
        self.documentStore = documentStore
    }

    func search(
        _ request: DocumentSearchRequest,
        progress: @escaping @Sendable (DocumentSearchProgress) -> Void
    ) async throws -> ProjectSearchReport {
        let documents = try await documentRepository.documents(in: request.projectID)
            .filter(Self.isSearchTarget)
            .sorted {
                $0.relativePath.rawValue.localizedStandardCompare($1.relativePath.rawValue) == .orderedAscending
            }
        let initialProgress = DocumentSearchProgress(
            completedDocumentCount: 0,
            totalDocumentCount: documents.count,
            hitCount: 0
        )
        progress(initialProgress)

        guard !request.query.isEmpty else {
            return ProjectSearchReport(
                hits: [],
                searchedDocumentCount: 0,
                totalDocumentCount: documents.count,
                issues: []
            )
        }

        var hits: [DocumentSearchHit] = []
        var issues: [DocumentSearchIssue] = []
        var searchedDocumentCount = 0

        for document in documents {
            try Task.checkCancellation()
            do {
                let snapshot = try await textSnapshot(for: document, request: request)
                hits.append(contentsOf: try Self.matches(
                    query: request.query,
                    in: snapshot.text,
                    document: snapshot.document
                ))
                searchedDocumentCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(
                    DocumentSearchIssue(
                        documentID: document.id,
                        relativePath: document.relativePath,
                        message: String(describing: error)
                    )
                )
            }
            progress(
                DocumentSearchProgress(
                    completedDocumentCount: searchedDocumentCount + issues.count,
                    totalDocumentCount: documents.count,
                    hitCount: hits.count
                )
            )
        }

        return ProjectSearchReport(
            hits: hits,
            searchedDocumentCount: searchedDocumentCount,
            totalDocumentCount: documents.count,
            issues: issues
        )
    }

    private func textSnapshot(
        for document: DocumentNode,
        request: DocumentSearchRequest
    ) async throws -> (document: DocumentNode, text: String) {
        if let override = request.textOverrides[document.id] {
            return (document, override)
        }

        do {
            return (document, try await documentStore.loadText(for: document))
        } catch {
            try Task.checkCancellation()
            guard let refreshed = try await documentRepository.document(id: document.id),
                  refreshed.projectID == request.projectID,
                  Self.isSearchTarget(refreshed)
            else {
                throw error
            }
            if let override = request.textOverrides[refreshed.id] {
                return (refreshed, override)
            }
            return (refreshed, try await documentStore.loadText(for: refreshed))
        }
    }

    private static func isSearchTarget(_ document: DocumentNode) -> Bool {
        guard document.kind == .text,
              case .active = document.deletionStatus
        else {
            return false
        }
        let components = document.relativePath.rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return !components.contains("휴지통") && !components.contains("백업")
    }

    private static func matches(
        query: String,
        in text: String,
        document: DocumentNode
    ) throws -> [DocumentSearchHit] {
        let source = text as NSString
        let queryLength = (query as NSString).length
        guard queryLength > 0 else { return [] }

        var results: [DocumentSearchHit] = []
        var searchLocation = 0
        while searchLocation <= source.length - queryLength {
            try Task.checkCancellation()
            let remaining = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let match = source.range(
                of: query,
                options: [.caseInsensitive, .literal],
                range: remaining
            )
            guard match.location != NSNotFound else { break }
            let excerpt = preview(for: match, in: source)
            results.append(
                DocumentSearchHit(
                    documentID: document.id,
                    relativePath: document.relativePath,
                    utf16Location: UInt(match.location),
                    utf16Length: UInt(match.length),
                    preview: excerpt.text,
                    previewUTF16Location: UInt(excerpt.matchLocation)
                )
            )
            searchLocation = NSMaxRange(match)
        }
        return results
    }

    private static func preview(
        for match: NSRange,
        in source: NSString
    ) -> (text: String, matchLocation: Int) {
        let radius = 80
        var start = max(0, match.location - radius)
        var end = min(source.length, NSMaxRange(match) + radius)
        let delimiters = CharacterSet(charactersIn: ".!?\n\r。！？")

        let prefixRange = NSRange(location: start, length: match.location - start)
        let previousDelimiter = source.rangeOfCharacter(
            from: delimiters,
            options: .backwards,
            range: prefixRange
        )
        if previousDelimiter.location != NSNotFound {
            start = NSMaxRange(previousDelimiter)
        }

        let suffixRange = NSRange(
            location: NSMaxRange(match),
            length: end - NSMaxRange(match)
        )
        let nextDelimiter = source.rangeOfCharacter(from: delimiters, range: suffixRange)
        if nextDelimiter.location != NSNotFound {
            end = NSMaxRange(nextDelimiter)
        }

        let composedRange = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: start, length: end - start)
        )
        start = composedRange.location
        end = NSMaxRange(composedRange)

        let hasLeadingEllipsis = start > 0
        let hasTrailingEllipsis = end < source.length
        var text = source.substring(with: NSRange(location: start, length: end - start))
        if hasLeadingEllipsis { text = "…" + text }
        if hasTrailingEllipsis { text += "…" }
        return (
            text,
            match.location - start + (hasLeadingEllipsis ? 1 : 0)
        )
    }
}
