import Foundation

extension LocalBinderCommandService {
    func move(
        documentID: DocumentID,
        toFolderID destinationID: DocumentID,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let source = try requireMutableDocument(documentID, in: documents)
        let destination = try requireDocument(destinationID, in: documents)
        guard destination.kind == .folder else {
            throw BinderCommandError.destinationIsNotFolder(destinationID)
        }
        if normalizedPathKey(destination.relativePath)
            == normalizedPathKey(BinderFixedCategory.trash.relativePath) {
            return try await moveToTrash(documentID: documentID, projectID: projectID)
        }
        guard !isInTrash(source.relativePath) else {
            throw BinderCommandError.fixedCategoryProtected("휴지통 항목")
        }

        let subtree = subtreeRooted(at: source, in: documents)
        try await requireNoOpenDocument(subtree, projectID: projectID)
        if source.id == destination.id
            || normalizedPathKey(destination.relativePath)
                .hasPrefix(normalizedPathKey(source.relativePath) + "/") {
            throw BinderCommandError.folderCannotMoveIntoItself
        }

        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let existingNames = try names(
            in: destination.relativePath,
            workspaceRoot: workspaceRoot
        )
        let manuscriptPaths = try manuscriptChapterPaths(workspaceRoot: workspaceRoot)
        let decision = ruleService.evaluateDrop(
            BinderMoveRuleRequest(
                sourcePath: source.relativePath,
                kind: source.kind,
                destinationFolderPath: destination.relativePath,
                existingDestinationNames: existingNames,
                existingManuscriptChapterPaths: manuscriptPaths
            )
        )
        try requireAllowed(
            decision,
            candidate: storedName(of: source.relativePath),
            existingNames: existingNames
        )

        let destinationPath = appending(
            storedName(of: source.relativePath),
            to: destination.relativePath
        )
        if destinationPath == source.relativePath {
            return BinderCommandResult(
                affectedDocumentID: source.id,
                relativePath: source.relativePath
            )
        }
        let siblings = documents.filter { $0.parentID == destination.id }
        let relocated = relocatedSubtree(
            subtree,
            source: source,
            destinationPath: destinationPath,
            destinationParentID: destination.id,
            rootOrder: (siblings.map(\.userOrder).max() ?? -1) + 1,
            trashed: false
        )
        let journal = relocationJournal(
            kind: .relocate,
            projectID: projectID,
            source: source,
            destinationPath: destinationPath,
            oldNodes: subtree,
            newNodes: relocated
        )
        try await execute(journal, workspaceRoot: workspaceRoot)
        return BinderCommandResult(affectedDocumentID: source.id, relativePath: destinationPath)
    }

    func execute(
        _ originalJournal: BinderCommandJournal,
        workspaceRoot: URL
    ) async throws {
        var journal = originalJournal
        let journalURL = transactionJournalURL(
            journal.transactionID,
            workspaceRoot: workspaceRoot
        )
        do {
            try writeJournal(journal, to: journalURL)
            try inject(.afterJournalWrite)

            try applyFiles(for: journal, workspaceRoot: workspaceRoot)
            journal.phase = .filesApplied
            try writeJournal(journal, to: journalURL)
            try inject(.afterFileMutation)

            try await saveMetadata(for: journal)
            journal.phase = .metadataSaved
            try writeJournal(journal, to: journalURL)
            try inject(.afterMetadataSave)

            try removeIfExists(journalURL)
        } catch let error as BinderCommandError {
            if case .injectedFailure(recoveryPending: true) = error {
                throw error
            }
            do {
                try await rollback(journal, workspaceRoot: workspaceRoot)
                try removeIfExists(journalURL)
            } catch {
                throw BinderCommandError.recoveryRequired(journalURL.path)
            }
            throw error
        } catch {
            do {
                try await rollback(journal, workspaceRoot: workspaceRoot)
                try removeIfExists(journalURL)
            } catch {
                throw BinderCommandError.recoveryRequired(journalURL.path)
            }
            throw error
        }
    }

    func saveMetadata(for journal: BinderCommandJournal) async throws {
        try await metadataStore.reconcileBinderMetadata(
            in: journal.projectID,
            upserting: journal.newNodes,
            removingSubtrees: []
        )
    }

    func rollback(
        _ journal: BinderCommandJournal,
        workspaceRoot: URL
    ) async throws {
        try rollbackFiles(for: journal, workspaceRoot: workspaceRoot)
        if journal.kind == .create {
            try await metadataStore.reconcileBinderMetadata(
                in: journal.projectID,
                upserting: [],
                removingSubtrees: journal.newNodes.first.map { [$0.id] } ?? []
            )
        } else {
            try await metadataStore.reconcileBinderMetadata(
                in: journal.projectID,
                upserting: journal.oldNodes,
                removingSubtrees: []
            )
        }
    }

    func applyFiles(
        for journal: BinderCommandJournal,
        workspaceRoot: URL
    ) throws {
        let destination = try validatedURL(
            journal.destinationPath,
            workspaceRoot: workspaceRoot
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw BinderCommandError.destinationAlreadyExists(
                destination.path,
                suggestedName: nil
            )
        }
        if let sourcePath = journal.sourcePath {
            let source = try validatedURL(sourcePath, workspaceRoot: workspaceRoot)
            guard fileManager.fileExists(atPath: source.path) else {
                throw BinderCommandError.sourceMissing(source.path)
            }
            try fileManager.moveItem(at: source, to: destination)
        } else if journal.createdKind == .folder {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
        } else {
            try Data().write(to: destination, options: [.atomic])
        }
    }

    func rollbackFiles(
        for journal: BinderCommandJournal,
        workspaceRoot: URL
    ) throws {
        let destination = try validatedURL(
            journal.destinationPath,
            workspaceRoot: workspaceRoot
        )
        if let sourcePath = journal.sourcePath {
            let source = try validatedURL(sourcePath, workspaceRoot: workspaceRoot)
            let sourceExists = fileManager.fileExists(atPath: source.path)
            let destinationExists = fileManager.fileExists(atPath: destination.path)
            if !sourceExists, destinationExists {
                try fileManager.moveItem(at: destination, to: source)
            } else if sourceExists, destinationExists {
                throw BinderCommandError.destinationAlreadyExists(destination.path, suggestedName: nil)
            } else if !sourceExists, !destinationExists {
                throw BinderCommandError.sourceMissing(source.path)
            }
        } else if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    func documentsAndRequireProject(
        _ projectID: ProjectID
    ) async throws -> [DocumentNode] {
        try await metadataStore.binderDocuments(in: projectID)
    }

    func requireDocument(
        _ id: DocumentID,
        in documents: [DocumentNode]
    ) throws -> DocumentNode {
        guard let document = documents.first(where: { $0.id == id }) else {
            throw BinderCommandError.missingDocument(id)
        }
        return document
    }

    func requireMutableDocument(
        _ id: DocumentID,
        in documents: [DocumentNode]
    ) throws -> DocumentNode {
        let document = try requireDocument(id, in: documents)
        if let category = fixedCategory(for: document.relativePath) {
            throw BinderCommandError.fixedCategoryProtected(category.displayName)
        }
        return document
    }

    func subtreeRooted(
        at source: DocumentNode,
        in documents: [DocumentNode]
    ) -> [DocumentNode] {
        let prefix = normalizedPathKey(source.relativePath)
        return documents.filter {
            let key = normalizedPathKey($0.relativePath)
            return key == prefix || key.hasPrefix(prefix + "/")
        }.sorted {
            $0.relativePath.rawValue.split(separator: "/").count
                < $1.relativePath.rawValue.split(separator: "/").count
        }
    }

    func relocatedSubtree(
        _ subtree: [DocumentNode],
        source: DocumentNode,
        destinationPath: RelativeDocumentPath,
        destinationParentID: DocumentID,
        rootOrder: Int,
        trashed: Bool
    ) -> [DocumentNode] {
        let now = clock.now()
        return subtree.map { document in
            let suffix = String(
                document.relativePath.rawValue.dropFirst(source.relativePath.rawValue.count)
            )
            let newPath = RelativeDocumentPath(
                rawValue: destinationPath.rawValue + suffix
            )
            let parentID = document.id == source.id
                ? destinationParentID
                : document.parentID
            let order = document.id == source.id ? rootOrder : document.userOrder
            if trashed {
                return DocumentNode(
                    id: document.id,
                    projectID: document.projectID,
                    kind: document.kind,
                    parentID: parentID,
                    relativePath: newPath,
                    userOrder: order,
                    modifiedAt: now,
                    contentHash: document.contentHash,
                    deletionStatus: .trashed(
                        originalPath: document.relativePath,
                        deletedAt: now
                    ),
                    cursor: document.cursor,
                    isExpanded: document.isExpanded
                )
            }
            return document.relocated(
                to: newPath,
                parentID: parentID,
                userOrder: order,
                at: now
            )
        }
    }

    func relocationJournal(
        kind: BinderCommandJournal.Kind,
        projectID: ProjectID,
        source: DocumentNode,
        destinationPath: RelativeDocumentPath,
        oldNodes: [DocumentNode],
        newNodes: [DocumentNode]
    ) -> BinderCommandJournal {
        BinderCommandJournal(
            transactionID: uuidGenerator.makeUUID(),
            projectID: projectID,
            kind: kind,
            phase: .prepared,
            sourcePath: source.relativePath,
            destinationPath: destinationPath,
            createdKind: nil,
            oldNodes: oldNodes,
            newNodes: newNodes
        )
    }

    func requireNoOpenDocument(
        _ subtree: [DocumentNode],
        projectID: ProjectID
    ) async throws {
        if try await containsOpenDocument(subtree, projectID: projectID),
           let text = subtree.first(where: { $0.kind == .text }) {
            throw BinderCommandError.openDocument(text.id)
        }
    }

    func containsOpenDocument(
        _ subtree: [DocumentNode],
        projectID: ProjectID
    ) async throws -> Bool {
        let state = try await workspaceStateRepository.editorState(for: projectID)
        let openIDs = Set([state.left.documentID, state.right?.documentID].compactMap { $0 })
        return subtree.contains { openIDs.contains($0.id) }
    }

    func requireAllowed(
        _ decision: BinderRuleDecision,
        candidate: String?,
        existingNames: [String]
    ) throws {
        guard case let .denied(violation) = decision else { return }
        let suggestion: String?
        if case .duplicateNormalizedName = violation, let candidate {
            suggestion = safeAlternativeName(candidate, existingNames: existingNames)
        } else {
            suggestion = nil
        }
        throw BinderCommandError.ruleDenied(
            reason: violation.userMessage,
            suggestedName: suggestion
        )
    }

    func storedName(
        from displayName: String,
        kind: DocumentKind
    ) throws -> String {
        if kind == .text {
            return try pathPolicy.textFileName(forDisplayName: displayName)
        }
        try pathPolicy.validateName(displayName)
        return displayName
    }

    func safeAlternativeName(
        _ candidate: String,
        existingNames: [String]
    ) -> String? {
        let hasTextExtension = candidate.lowercased().hasSuffix(".txt")
        let base = hasTextExtension ? String(candidate.dropLast(4)) : candidate
        let suffix = hasTextExtension ? ".txt" : ""
        for number in 2...999 {
            let proposed = "\(base) \(number)\(suffix)"
            if (try? pathPolicy.validateUniqueName(proposed, among: existingNames)) != nil {
                return proposed
            }
        }
        return nil
    }

    func names(
        in relativePath: RelativeDocumentPath,
        workspaceRoot: URL
    ) throws -> [String] {
        let url = try validatedURL(relativePath, workspaceRoot: workspaceRoot)
        return try fileManager.contentsOfDirectory(atPath: url.path)
    }

    func manuscriptChapterPaths(
        workspaceRoot: URL
    ) throws -> [RelativeDocumentPath] {
        let manuscriptURL = try validatedURL(
            BinderFixedCategory.manuscript.relativePath,
            workspaceRoot: workspaceRoot
        )
        guard let enumerator = fileManager.enumerator(
            at: manuscriptURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let rootPrefix = workspaceRoot.standardizedFileURL.path + "/"
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.path.hasPrefix(rootPrefix)
            else {
                return nil
            }
            return RelativeDocumentPath(rawValue: String(url.path.dropFirst(rootPrefix.count)))
        }
    }

    func validatedURL(
        _ relativePath: RelativeDocumentPath,
        workspaceRoot: URL
    ) throws -> URL {
        try pathPolicy.validateRelativePath(relativePath)
        let root = workspaceRoot.standardizedFileURL
        let result = relativePath.rawValue.split(separator: "/").reduce(root) {
            $0.appendingPathComponent(String($1))
        }.standardizedFileURL
        guard result.path.hasPrefix(root.path + "/") else {
            throw BinderCommandError.destinationOutsideProject
        }
        return result
    }

    func fixedCategory(
        for path: RelativeDocumentPath
    ) -> BinderFixedCategory? {
        BinderFixedCategory.allCases.first {
            normalizedPathKey($0.relativePath) == normalizedPathKey(path)
        }
    }

    func isInTrash(_ path: RelativeDocumentPath) -> Bool {
        let key = normalizedPathKey(path)
        let trashKey = normalizedPathKey(BinderFixedCategory.trash.relativePath)
        return key == trashKey || key.hasPrefix(trashKey + "/")
    }

    func normalizedPathKey(_ path: RelativeDocumentPath) -> String {
        path.rawValue.split(separator: "/")
            .map { pathPolicy.collisionKey(for: String($0)) }
            .joined(separator: "/")
    }

    func storedName(of path: RelativeDocumentPath) -> String {
        path.rawValue.split(separator: "/").last.map(String.init) ?? ""
    }

    func appending(
        _ name: String,
        to parent: RelativeDocumentPath
    ) -> RelativeDocumentPath {
        RelativeDocumentPath(rawValue: parent.rawValue + "/" + name)
    }

    func transactionJournalURL(
        _ transactionID: UUID,
        workspaceRoot: URL
    ) -> URL {
        workspaceRoot.appendingPathComponent(
            Self.journalPrefix
                + transactionID.uuidString.lowercased()
                + Self.journalSuffix
        )
    }

    func writeJournal(
        _ journal: BinderCommandJournal,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: url, options: [.atomic])
    }

    func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func inject(_ point: BinderCommandFaultPoint) throws {
        guard faultPlan?.point == point else { return }
        throw BinderCommandError.injectedFailure(
            recoveryPending: faultPlan?.leavesTransactionForRecovery == true
        )
    }
}
