import Foundation

extension LocalBinderCommandService {
    /// 구형 Windows 표시명이 실제 루트 경로로 수신된 13-2 초기 빌드의 흔적만
    /// 정리한다. 정확한 UUIDv5, 빈 폴더, 하위 메타데이터 없음이 모두 확인돼야 한다.
    func removeEmptyLegacySyncRootAliases(
        in projectID: ProjectID,
        workspaceRoot: URL
    ) async throws {
        let aliases = [
            "📚 원고",
            "👤 캐릭터",
            "📖 설정집",
            "📝 메모장",
            "🗺️ 메인 스토리 틀",
            "🌊 흐름 정리",
            "🔍 복선",
            "📌 장소",
            "🗑️ 휴지통",
        ].map { RelativeDocumentPath(rawValue: "메인/\($0)") }
        let documents = try await metadataStore.binderDocuments(in: projectID)
        var conflicts: [String] = []
        var cleanups: [(url: URL, document: DocumentNode, existed: Bool)] = []

        for path in aliases {
            let key = normalizedPathKey(path)
            let matching = documents.filter {
                let documentKey = normalizedPathKey($0.relativePath)
                return documentKey == key || documentKey.hasPrefix(key + "/")
            }
            let exact = matching.first {
                normalizedPathKey($0.relativePath) == key
            }
            let url = try validatedURL(path, workspaceRoot: workspaceRoot)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
            guard exists || exact != nil else { continue }

            let expectedID = DocumentID(
                rawValue: syncV2UUIDv5(
                    namespace: projectID.rawValue,
                    name: "writerpad-local-folder/" + key
                )
            )
            let isSafeMetadata = exact?.kind == .folder
                && exact?.id == expectedID
                && matching.count == 1
            let isSafeDirectory: Bool
            if exists {
                let isSymbolicLink = (try? url.resourceValues(
                    forKeys: [.isSymbolicLinkKey]
                ).isSymbolicLink) == true
                let isEmpty = isDirectory.boolValue
                    && !isSymbolicLink
                    && (try? fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: []
                    ).isEmpty) == true
                isSafeDirectory = isEmpty
            } else {
                isSafeDirectory = true
            }
            guard isSafeMetadata, isSafeDirectory, let exact else {
                conflicts.append(path.rawValue)
                continue
            }

            cleanups.append((url: url, document: exact, existed: exists))
        }
        guard conflicts.isEmpty else {
            throw BinderCommandError.legacySyncFolderConflict(conflicts)
        }

        var completed: [(url: URL, document: DocumentNode, existed: Bool)] = []
        do {
            for cleanup in cleanups {
                if cleanup.existed {
                    try fileManager.removeItem(at: cleanup.url)
                }
                completed.append(cleanup)
                try await metadataStore.reconcileBinderMetadata(
                    in: projectID,
                    upserting: [],
                    removingSubtrees: [cleanup.document.id]
                )
            }
        } catch {
            for cleanup in completed.reversed() {
                if cleanup.existed {
                    try? fileManager.createDirectory(
                        at: cleanup.url,
                        withIntermediateDirectories: false
                    )
                }
                try? await metadataStore.reconcileBinderMetadata(
                    in: projectID,
                    upserting: [cleanup.document],
                    removingSubtrees: []
                )
            }
            throw error
        }
    }

    /// 13-2 호환 전환: 구형 플롯 루트는 UUID와 하위 메타데이터를 유지한 채
    /// 새 고정 루트로 한 번만 이동한다. 둘 이상이 공존하면 병합하지 않는다.
    func ensureCanonicalStoryPlotFolder(
        in projectID: ProjectID,
        workspaceRoot: URL
    ) async throws {
        let canonicalPath = BinderFixedCategory.storyPlot.relativePath
        let legacyPaths = [
            ProjectPathResolver.legacyPlotPath,
            ProjectPathResolver.legacyMainStoryPath,
        ]
        let candidatePaths = [canonicalPath] + legacyPaths
        var diskPaths: [RelativeDocumentPath] = []

        for path in candidatePaths {
            let url = try validatedURL(path, workspaceRoot: workspaceRoot)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) else { continue }
            let isSymbolicLink = (try? url.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink) == true
            guard isDirectory.boolValue,
                  !isSymbolicLink
            else {
                throw BinderCommandError.storyPlotMigrationConflict([
                    path.rawValue,
                ])
            }
            diskPaths.append(path)
        }

        let canonicalExists = diskPaths.contains(canonicalPath)
        let existingLegacyPaths = legacyPaths.filter(diskPaths.contains)
        if canonicalExists {
            guard existingLegacyPaths.isEmpty else {
                throw BinderCommandError.storyPlotMigrationConflict(
                    ([canonicalPath] + existingLegacyPaths).map(\.rawValue)
                )
            }
            return
        }
        guard existingLegacyPaths.count <= 1 else {
            throw BinderCommandError.storyPlotMigrationConflict(
                existingLegacyPaths.map(\.rawValue)
            )
        }

        let documents = try await metadataStore.binderDocuments(in: projectID)
        let canonicalKey = normalizedPathKey(canonicalPath)
        let metadataAtCanonicalPath = documents.filter {
            let key = normalizedPathKey($0.relativePath)
            return key == canonicalKey || key.hasPrefix(canonicalKey + "/")
        }

        guard let legacyPath = existingLegacyPaths.first else {
            let staleLegacyPaths = legacyPaths.filter { path in
                let key = normalizedPathKey(path)
                return documents.contains {
                    let documentKey = normalizedPathKey($0.relativePath)
                    return documentKey == key || documentKey.hasPrefix(key + "/")
                }
            }
            guard metadataAtCanonicalPath.allSatisfy({ $0.kind == .folder })
                    || metadataAtCanonicalPath.isEmpty,
                  staleLegacyPaths.isEmpty
            else {
                throw BinderCommandError.storyPlotMigrationConflict(
                    (staleLegacyPaths + [canonicalPath]).map(\.rawValue)
                )
            }
            let destination = try validatedURL(
                canonicalPath,
                workspaceRoot: workspaceRoot
            )
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            return
        }

        guard metadataAtCanonicalPath.isEmpty else {
            throw BinderCommandError.storyPlotMigrationConflict(
                [legacyPath.rawValue, canonicalPath.rawValue]
            )
        }
        let legacyKey = normalizedPathKey(legacyPath)
        let oldNodes = documents.filter {
            let key = normalizedPathKey($0.relativePath)
            return key == legacyKey || key.hasPrefix(legacyKey + "/")
        }.sorted {
            $0.relativePath.rawValue.split(separator: "/").count
                < $1.relativePath.rawValue.split(separator: "/").count
        }
        if let source = oldNodes.first(where: {
            normalizedPathKey($0.relativePath) == legacyKey
        }) {
            guard source.kind == .folder,
                  let parentID = source.parentID
            else {
                throw BinderCommandError.storyPlotMigrationConflict([
                    legacyPath.rawValue,
                ])
            }
            let newNodes = relocatedSubtree(
                oldNodes,
                source: source,
                destinationPath: canonicalPath,
                destinationParentID: parentID,
                rootOrder: source.userOrder,
                trashed: false
            )
            let journal = relocationJournal(
                kind: .relocate,
                projectID: projectID,
                source: source,
                destinationPath: canonicalPath,
                oldNodes: oldNodes,
                newNodes: newNodes
            )
            try await execute(journal, workspaceRoot: workspaceRoot)
            return
        }

        // 아직 스캔되지 않은 구형 폴더는 파일 시스템 이름만 원자적으로 바꾼다.
        // 다음 rootNodes 스캔에서 새 고정 루트 메타데이터가 생성된다.
        let source = try validatedURL(legacyPath, workspaceRoot: workspaceRoot)
        let destination = try validatedURL(canonicalPath, workspaceRoot: workspaceRoot)
        try fileManager.moveItem(at: source, to: destination)
    }

    func addNewVolume(projectID: ProjectID) async throws -> BinderVolumeCreationResult {
        guard volumeCreationProjects.insert(projectID).inserted else {
            throw BinderCommandError.volumeCreationInProgress
        }
        defer { volumeCreationProjects.remove(projectID) }

        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        guard let manuscript = documents.first(where: {
            fixedCategory(for: $0.relativePath) == .manuscript && $0.kind == .folder
        }) else {
            throw BinderCommandError.missingManuscriptRoot
        }

        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let volumeNumbers = try validVolumeNumbers(workspaceRoot: workspaceRoot)
        let highestVolume = volumeNumbers.max() ?? 0
        guard highestVolume < Int.max else {
            throw BinderCommandError.volumeNumberOverflow
        }
        let volumeNumber = highestVolume + 1
        let (endChapter, overflow) = volumeNumber.multipliedReportingOverflow(by: 25)
        guard !overflow else { throw BinderCommandError.volumeNumberOverflow }
        let startChapter = endChapter - 24
        let chapterNumbers = Array(startChapter...endChapter)

        let volumeName = "\(volumeNumber)권"
        let volumePath = appending(volumeName, to: manuscript.relativePath)
        let manuscriptNames = try names(
            in: manuscript.relativePath,
            workspaceRoot: workspaceRoot
        )
        try requireAllowed(
            ruleService.evaluateCreation(
                BinderCreationRuleRequest(
                    parentPath: manuscript.relativePath,
                    kind: .folder,
                    storedName: volumeName,
                    existingSiblingNames: manuscriptNames
                )
            ),
            candidate: volumeName,
            existingNames: manuscriptNames
        )

        let existingChapterPaths = try manuscriptChapterPaths(workspaceRoot: workspaceRoot)
        let existingChapterNumbers = Set(existingChapterPaths.compactMap {
            ruleService.titledChapterIdentity(fromStoredName: storedName(of: $0))?.number
        })
        if let collision = chapterNumbers.first(where: existingChapterNumbers.contains) {
            throw BinderCommandError.chapterAlreadyExists(collision)
        }

        let chapterNames = chapterNumbers.map(chapterFileName)
        for (index, name) in chapterNames.enumerated() {
            try requireAllowed(
                ruleService.evaluateCreation(
                    BinderCreationRuleRequest(
                        parentPath: volumePath,
                        kind: .text,
                        storedName: name,
                        existingSiblingNames: Array(chapterNames.prefix(index)),
                        existingManuscriptChapterPaths: existingChapterPaths
                    )
                ),
                candidate: name,
                existingNames: Array(chapterNames.prefix(index))
            )
        }

        let now = clock.now()
        let volumeID = DocumentID(rawValue: uuidGenerator.makeUUID())
        let manuscriptSiblings = documents.filter { $0.parentID == manuscript.id }
        let volume = DocumentNode(
            id: volumeID,
            projectID: projectID,
            kind: .folder,
            parentID: manuscript.id,
            relativePath: volumePath,
            userOrder: (manuscriptSiblings.map(\.userOrder).max() ?? -1) + 1,
            modifiedAt: now,
            contentHash: nil,
            isExpanded: true
        )
        let emptyHash = hasher.sha256(for: Data())
        let chapters = zip(chapterNumbers, chapterNames).enumerated().map { index, pair in
            let (_, name) = pair
            return DocumentNode(
                id: DocumentID(rawValue: uuidGenerator.makeUUID()),
                projectID: projectID,
                kind: .text,
                parentID: volumeID,
                relativePath: appending(name, to: volumePath),
                userOrder: index,
                modifiedAt: now,
                contentHash: emptyHash
            )
        }
        guard let firstChapter = chapters.first else {
            throw BinderCommandError.volumeNumberOverflow
        }

        let journal = BinderCommandJournal(
            transactionID: uuidGenerator.makeUUID(),
            projectID: projectID,
            kind: .createVolume,
            phase: .prepared,
            sourcePath: nil,
            destinationPath: volumePath,
            createdKind: .folder,
            oldNodes: [],
            newNodes: [volume] + chapters,
            trashRecord: nil
        )
        try await execute(journal, workspaceRoot: workspaceRoot)
        await futureChangeNotifier.record(
            .manuscriptVolumeCreated(
                projectID: projectID,
                volumeID: volumeID,
                chapterIDs: chapters.map(\.id)
            )
        )
        return BinderVolumeCreationResult(
            volumeNumber: volumeNumber,
            volumeID: volumeID,
            firstChapterID: firstChapter.id,
            chapterIDs: chapters.map(\.id),
            volumePath: volumePath,
            shouldRefreshBinder: true,
            manuscriptFolderID: manuscript.id,
            folderToExpandID: volumeID,
            documentToOpenID: firstChapter.id
        )
    }

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
        try requireValidHierarchyPlacement(kind: source.kind, in: destination)
        if normalizedPathKey(destination.relativePath)
            == normalizedPathKey(BinderFixedCategory.trash.relativePath) {
            return try await moveToTrash(documentID: documentID, projectID: projectID)
        }
        guard !isInTrash(source.relativePath) else {
            throw BinderCommandError.fixedCategoryProtected("휴지통 항목")
        }

        let subtree = subtreeRooted(at: source, in: documents)
        try await requireNoOpenDocument(subtree, projectID: projectID)
        try await createStructuralBackups(for: subtree)
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
        let originalStoredName = storedName(of: source.relativePath)
        let isSameParent = source.parentID == destination.id
        let candidate = isSameParent || isInManuscript(source.relativePath)
            ? originalStoredName
            : numberedCollisionName(originalStoredName, existingNames: existingNames)
        let manuscriptPaths = try manuscriptChapterPaths(workspaceRoot: workspaceRoot)
        let decision = ruleService.evaluateDrop(
            BinderMoveRuleRequest(
                sourcePath: source.relativePath,
                kind: source.kind,
                destinationFolderPath: destination.relativePath,
                proposedStoredName: candidate,
                existingDestinationNames: existingNames,
                existingManuscriptChapterPaths: manuscriptPaths
            )
        )
        try requireAllowed(
            decision,
            candidate: candidate,
            existingNames: existingNames
        )

        let destinationPath = appending(
            candidate,
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
        var documentIDs = (originalJournal.oldNodes + originalJournal.newNodes)
            .filter { $0.kind == .text }
            .map { $0.id.rawValue }
        // 빈 폴더는 text UUID가 없어 기존 코드에서는 Gate를
        // 그냥 통과했다. 원격 폴더 반영과 새 폴더 생성이
        // 충돌하지 않도록 작품별 구조 키도 함께 사용한다.
        documentIDs.append(
            syncV2ProjectStructureMutationID(originalJournal.projectID)
        )
        try await syncMutationGate.withCriticalSections(
            documentIDs: documentIDs
        ) { [self] in
            try await executeInsideMutationGate(
                originalJournal,
                workspaceRoot: workspaceRoot
            )
        }
    }

    private func executeInsideMutationGate(
        _ originalJournal: BinderCommandJournal,
        workspaceRoot: URL
    ) async throws {
        var journal = originalJournal
        let journalURL = transactionJournalURL(
            journal.transactionID,
            workspaceRoot: workspaceRoot
        )
        var localTransactionCommitted = false
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
            localTransactionCommitted = true
            try inject(.afterMetadataSave)
        } catch let error as BinderCommandError {
            if case .injectedFailure(recoveryPending: true) = error {
                throw error
            }
            if localTransactionCommitted {
                return
            }
            do {
                try await rollback(journal, workspaceRoot: workspaceRoot)
                try removeIfExists(journalURL)
            } catch {
                throw BinderCommandError.recoveryRequired(journalURL.path)
            }
            throw error
        } catch {
            if localTransactionCommitted {
                return
            }
            do {
                try await rollback(journal, workspaceRoot: workspaceRoot)
                try removeIfExists(journalURL)
            } catch {
                throw BinderCommandError.recoveryRequired(journalURL.path)
            }
            throw error
        }

        do {
            guard try await completeDurableHandoff(
                journal: &journal,
                journalURL: journalURL,
                workspaceRoot: workspaceRoot
            ) else {
                return
            }
            if journal.kind == .permanentDelete {
                try removeIfExists(
                    try validatedURL(
                        journal.destinationPath,
                        workspaceRoot: workspaceRoot
                    )
                )
            }
            if journal.kind == .restore || journal.kind == .permanentDelete,
               let record = journal.trashRecord {
                try removeIfExists(
                    trashRecordURL(
                        record.documentID,
                        workspaceRoot: workspaceRoot
                    )
                )
            }
            try removeIfExists(journalURL)
        } catch {
            // 로컬 transaction은 이미 완료됐다. 저널을 남겨 다음 실행에서
            // 동일 batch/operation ID로 재등록하며 로컬 성공은 되돌리지 않는다.
        }
    }

    func completeDurableHandoff(
        journal: inout BinderCommandJournal,
        journalURL: URL,
        workspaceRoot: URL
    ) async throws -> Bool {
        let requirement = await durableChangeRecorder.requirement(
            for: journal.projectID
        )
        guard requirement == .durableQueue else {
            return true
        }
        if journal.durableBatch == nil {
            journal.durableBatch = try await durableBatch(
                for: journal,
                workspaceRoot: workspaceRoot
            )
            try writeJournal(journal, to: journalURL)
        }
        guard let batch = journal.durableBatch else {
            return true
        }
        switch await durableChangeRecorder.record(batch) {
        case .queued, .notNeeded, .serverSizeLimitExceeded:
            return true
        case .localOnly, .localSavedButNotQueued:
            return false
        }
    }

    func durableBatch(
        for journal: BinderCommandJournal,
        workspaceRoot: URL
    ) async throws -> LocalMutationBatch? {
        let batchKind: DurableLocalBatchKind
        switch journal.kind {
        case .create, .relocate, .reorder:
            batchKind = .structureChange
        case .createVolume:
            batchKind = .volumeCreation
        case .trash, .restore, .permanentDelete, .emptyTrash:
            batchKind = .trashChange
        }

        var mutations: [DurableLocalMutation] = []
        switch journal.kind {
        case .trash:
            for node in journal.oldNodes
                .filter({ $0.kind == .text })
                .sorted(by: { $0.relativePath.rawValue < $1.relativePath.rawValue }) {
                guard let trashed = journal.newNodes.first(where: {
                    $0.id == node.id && $0.kind == .text
                }) else {
                    throw BinderCommandError.missingDocument(node.id)
                }
                let url = try validatedURL(
                    trashed.relativePath,
                    workspaceRoot: workspaceRoot
                )
                let data = try Data(contentsOf: url)
                guard let content = String(data: data, encoding: .utf8) else {
                    throw LocalDocumentStoreError.invalidUTF8(url.path)
                }
                mutations.append(
                    .documentSnapshot(
                        operationID: uuidGenerator.makeUUID(),
                        documentID: node.id,
                        relativePath: node.relativePath,
                        content: content,
                        contentHash: hasher.sha256(for: data),
                        localSaveGeneration: 0,
                        isDeleted: true
                    )
                )
            }
        case .permanentDelete, .emptyTrash:
            let purged = Dictionary(
                uniqueKeysWithValues: journal.oldNodes
                    .filter { $0.kind == .text }
                    .map { ($0.id.rawValue.uuidString.lowercased(), 0) }
            )
            let content = try canonicalJSON([
                "version": 1,
                "purged_revisions": purged,
                "empty_generation": journal.kind == .emptyTrash
                    ? journal.transactionID.uuidString.lowercased()
                    : "",
            ])
            mutations.append(
                .trashPurge(
                    operationID: uuidGenerator.makeUUID(),
                    content: content,
                    generation: journal.transactionID
                )
            )
        case .create, .createVolume, .relocate, .restore:
            for node in journal.newNodes
                .filter({ $0.kind == .text })
                .sorted(by: { $0.relativePath.rawValue < $1.relativePath.rawValue }) {
                let url = try validatedURL(
                    node.relativePath,
                    workspaceRoot: workspaceRoot
                )
                let data = try Data(contentsOf: url)
                guard let content = String(data: data, encoding: .utf8) else {
                    throw LocalDocumentStoreError.invalidUTF8(url.path)
                }
                mutations.append(
                    .documentSnapshot(
                        operationID: uuidGenerator.makeUUID(),
                        documentID: node.id,
                        relativePath: node.relativePath,
                        content: content,
                        contentHash: hasher.sha256(for: data),
                        localSaveGeneration: 0,
                        isDeleted: false
                    )
                )
            }
        case .reorder:
            break
        }

        // 새 권은 장 문서보다 권 폴더를 먼저 durable queue에 둔다. 실제 claim도
        // volume_creation 폴더 장벽을 쓰지만, 재시작 뒤 queue 순서와 감사 기록도
        // "권 폴더 -> 장 문서 -> tree_order"를 그대로 보여야 한다.
        let folders = folderMutations(for: journal)
        if journal.kind == .createVolume {
            mutations.insert(contentsOf: folders, at: 0)
        } else {
            // 폴더 자체를 서버에 알린다. tree_order는 이름 목록이라 이름이 바뀌면
            // "옛 이름 사라짐 + 새 이름 생김"으로 도착한다. 같은 folder_id로
            // 보내야 받는 기기가 옮기기로 처리한다.
            mutations.append(contentsOf: folders)
        }

        if journal.kind != .permanentDelete && journal.kind != .emptyTrash {
            let documents = try await metadataStore.binderDocuments(
                in: journal.projectID
            )
            let generation = UInt64(
                max(0, Int(clock.now().timeIntervalSince1970 * 1_000))
            )
            mutations.append(
                .treeOrder(
                    operationID: uuidGenerator.makeUUID(),
                    content: try treeOrderContent(documents: documents),
                    generation: generation
                )
            )
        }
        guard !mutations.isEmpty else { return nil }
        return LocalMutationBatch(
            batchID: uuidGenerator.makeUUID(),
            projectID: journal.projectID,
            localTransactionID: journal.transactionID,
            kind: batchKind,
            mutations: mutations
        )
    }

    /// 바인더 명령 하나가 만든 폴더 변경을 대기열 작업으로 바꾼다.
    ///
    /// 식별자는 `DocumentNode.id`를 그대로 쓴다. 이름 변경과 이동은 같은 노드가
    /// 경로만 바뀌어 오므로 folder_id가 저절로 유지되고, 새로 만든 폴더만 새
    /// UUID를 갖는다.
    ///
    /// operation_id는 여기서 한 번만 만든다. 이 batch는 저널에 적혀 재시도에
    /// 그대로 다시 쓰이므로, 끊겼다 이어져도 같은 값이 나간다.
    func folderMutations(
        for journal: BinderCommandJournal
    ) -> [DurableLocalMutation] {
        switch journal.kind {
        case .reorder:
            // 순서만 바뀐다. 이름도 부모도 그대로라 보낼 것이 없다.
            return []
        case .create, .createVolume:
            return folderCommits(
                for: journal.newNodes,
                isDeleted: false
            )
        case .relocate:
            // 이름이나 부모가 실제로 바뀐 폴더만 보낸다. 자식은 부모를 따라
            // 경로가 바뀌지만 제 이름과 부모 연결은 그대로다.
            let previous = Dictionary(
                journal.oldNodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let changed = journal.newNodes.filter { node in
                guard let old = previous[node.id] else { return true }
                return folderName(of: node) != folderName(of: old)
                    || node.parentID != old.parentID
            }
            return folderCommits(for: changed, isDeleted: false)
        case .trash:
            return folderCommits(for: journal.newNodes, isDeleted: true)
        case .restore:
            return folderCommits(for: journal.newNodes, isDeleted: false)
        case .permanentDelete, .emptyTrash:
            // 휴지통으로 옮길 때 이미 무덤을 보냈다. 여기서 또 보내면 같은
            // 폴더의 revision만 올라간다.
            return []
        }
    }

    private func folderCommits(
        for nodes: [DocumentNode],
        isDeleted: Bool
    ) -> [DurableLocalMutation] {
        nodes
            .filter { $0.kind == .folder }
            // 부모가 먼저 서버에 있어야 자식의 parent_folder_id가 가리킬
            // 대상이 있다. 지울 때는 반대로 깊은 것부터 나가야 서버가
            // FOLDER_NOT_EMPTY로 거부하지 않는다.
            .sorted {
                let left = $0.relativePath.rawValue
                    .split(separator: "/").count
                let right = $1.relativePath.rawValue
                    .split(separator: "/").count
                return isDeleted ? left > right : left < right
            }
            .map { node in
                .folderSnapshot(
                    operationID: uuidGenerator.makeUUID(),
                    folderID: node.id,
                    parentFolderID: node.parentID,
                    name: folderName(of: node),
                    isDeleted: isDeleted
                )
            }
    }

    private func folderName(of node: DocumentNode) -> String {
        SyncV2FolderMigration.folderName(node.relativePath)
    }

    func recordEmptyTrashHandoff(
        projectID: ProjectID,
        deletedNodes: [DocumentNode],
        trashPath: RelativeDocumentPath
    ) async {
        guard !deletedNodes.isEmpty,
              await durableChangeRecorder.requirement(for: projectID)
                == .durableQueue,
              let workspaceRoot = try? await workspaceLocator.workspaceRoot(
                for: projectID
              )
        else {
            return
        }
        let transactionID = uuidGenerator.makeUUID()
        var journal = BinderCommandJournal(
            transactionID: transactionID,
            projectID: projectID,
            kind: .emptyTrash,
            phase: .metadataSaved,
            sourcePath: nil,
            destinationPath: trashPath,
            createdKind: nil,
            oldNodes: deletedNodes,
            newNodes: [],
            trashRecord: nil
        )
        let journalURL = transactionJournalURL(
            transactionID,
            workspaceRoot: workspaceRoot
        )
        do {
            journal.durableBatch = try await durableBatch(
                for: journal,
                workspaceRoot: workspaceRoot
            )
            try writeJournal(journal, to: journalURL)
            if try await completeDurableHandoff(
                journal: &journal,
                journalURL: journalURL,
                workspaceRoot: workspaceRoot
            ) {
                try removeIfExists(journalURL)
            }
        } catch {
            // 삭제 결과는 이미 확정됐다. 표식이 만들어졌다면 복구 경로가 재시도한다.
        }
    }

    func treeOrderContent(documents: [DocumentNode]) throws -> String {
        let live = documents.filter {
            if case .active = $0.deletionStatus {
                return !isInTrash($0.relativePath)
            }
            return false
        }
        let folders = live.filter { $0.kind == .folder }
        var order: [String: [String]] = [:]
        for parent in folders {
            let children = live
                .filter { $0.parentID == parent.id }
                .sorted {
                    if $0.userOrder != $1.userOrder {
                        return $0.userOrder < $1.userOrder
                    }
                    return $0.relativePath.rawValue < $1.relativePath.rawValue
                }
            let rawKey = hierarchyPolicy.isTopLevelContainer(parent)
                ? "<root>"
                : parent.relativePath.rawValue
            let key = rawKey == "<root>"
                ? rawKey
                : SyncV2ServerPath.canonical(rawKey)
            // iOS 파일시스템은 한글 경로를 NFD로 되돌려줄 수
            // 있다. folders 행은 NFC로 보내므로 tree_order도 같은
            // 바이트 규약을 써야 Windows가 같은 폴더로 인식한다.
            // 빈 폴더도 []로 명시해 문서 경로 없이 구조가
            // 완전하게 전달되도록 한다.
            order[key] = children.map {
                SyncV2ServerPath.canonical(storedName(of: $0.relativePath))
            }
        }
        return try canonicalJSON([
            "version": 1,
            "tree_order": order,
        ])
    }

    func canonicalJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw BinderCommandError.recoveryRequired("canonical-json")
        }
        return value
    }

    func saveMetadata(for journal: BinderCommandJournal) async throws {
        let existing = try await metadataStore.binderDocuments(in: journal.projectID)
        let rootIDs = Set(
            (existing + journal.newNodes)
                .filter(hierarchyPolicy.isTopLevelContainer)
                .map(\.id)
        )
        if journal.newNodes.contains(where: {
            $0.kind == .text && $0.parentID.map(rootIDs.contains) == true
        }) {
            throw BinderCommandError.topLevelRequiresFolder
        }
        try await metadataStore.reconcileBinderMetadata(
            in: journal.projectID,
            upserting: journal.newNodes,
            removingSubtrees: journal.kind == .permanentDelete
                ? journal.oldNodes.first.map { [$0.id] } ?? []
                : []
        )
    }

    func rollback(
        _ journal: BinderCommandJournal,
        workspaceRoot: URL
    ) async throws {
        try rollbackFiles(for: journal, workspaceRoot: workspaceRoot)
        if journal.kind == .create || journal.kind == .createVolume {
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
        if journal.kind == .trash, let record = journal.trashRecord {
            try removeIfExists(trashRecordURL(record.documentID, workspaceRoot: workspaceRoot))
        }
    }

    func applyFiles(
        for journal: BinderCommandJournal,
        workspaceRoot: URL
    ) throws {
        if journal.kind == .reorder || journal.kind == .emptyTrash {
            return
        }
        if journal.kind == .createVolume {
            try applyVolumeFiles(for: journal, workspaceRoot: workspaceRoot)
            return
        }
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
        if journal.kind == .reorder || journal.kind == .emptyTrash {
            return
        }
        if journal.kind == .createVolume {
            try removeIfExists(
                try validatedURL(
                    volumeTemporaryPath(for: journal),
                    workspaceRoot: workspaceRoot
                )
            )
            try removeIfExists(
                try validatedURL(journal.destinationPath, workspaceRoot: workspaceRoot)
            )
            return
        }
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
        let documents = try await metadataStore.binderDocuments(in: projectID)
        let invalid = hierarchyPolicy.invalidTopLevelDocuments(in: documents)
        if !invalid.isEmpty {
            let paths = invalid.map(\.relativePath.rawValue).joined(separator: ", ")
            hierarchyLogger.fault(
                "Invalid top-level binder documents detected; no automatic mutation performed: \(paths)"
            )
        }
        return documents
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
            return DocumentNode(
                id: document.id,
                projectID: document.projectID,
                kind: document.kind,
                parentID: parentID,
                relativePath: newPath,
                userOrder: order,
                modifiedAt: now,
                contentHash: document.contentHash,
                deletionStatus: .active,
                cursor: document.cursor,
                isExpanded: document.isExpanded
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
            newNodes: newNodes,
            trashRecord: kind == .trash ? TrashRecord(
                documentID: source.id,
                originalPath: source.relativePath,
                originalParentID: source.parentID!,
                originalUserOrder: source.userOrder,
                deletedAt: clock.now()
            ) : nil
        )
    }

    func trashRecordURL(_ id: DocumentID, workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(
            ".writerpad-trash-" + id.rawValue.uuidString.lowercased() + ".json"
        )
    }

    func writeTrashRecord(_ record: TrashRecord, workspaceRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: trashRecordURL(record.documentID, workspaceRoot: workspaceRoot),
            options: [.atomic]
        )
    }

    func readTrashRecord(_ id: DocumentID, workspaceRoot: URL) throws -> TrashRecord {
        let url = trashRecordURL(id, workspaceRoot: workspaceRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BinderCommandError.trashRecordMissing(id)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TrashRecord.self, from: Data(contentsOf: url))
    }

    func createStructuralBackups(for subtree: [DocumentNode]) async throws {
        guard let backupStore, let backupPolicyStore,
              let projectID = subtree.first?.projectID else { return }
        let policy = try await backupPolicyStore.policy(for: projectID)
        guard policy.isAutomaticBackupEnabled else { return }
        for document in subtree where document.kind == .text {
            _ = try await backupStore.createSnapshot(
                for: document,
                reason: .beforeStructureChange
            )
        }
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

    func requireValidHierarchyPlacement(
        kind: DocumentKind,
        in destinationParent: DocumentNode
    ) throws {
        guard hierarchyPolicy.placementViolation(
            for: kind,
            in: destinationParent
        ) == nil else {
            throw BinderCommandError.topLevelRequiresFolder
        }
    }

    func storedName(
        from displayName: String,
        kind: DocumentKind
    ) throws -> String {
        if kind == .text {
            return try pathPolicy.textFileName(forDisplayName: displayName)
        }
        // 폴더 이름도 파일과 같은 관문을 지난다. 정리에 실패하면 던져서
        // 파일 시스템과 서버를 건드리지 않는다.
        return try pathPolicy.sanitizedName(displayName)
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

    /// 같은 이름을 거부하지 않고 확장자 앞에 `_2`, `_3`을 붙여 안전하게 공존시킨다.
    func numberedCollisionName(
        _ candidate: String,
        existingNames: [String]
    ) -> String {
        if (try? pathPolicy.validateUniqueName(candidate, among: existingNames)) != nil {
            return candidate
        }
        let hasTextExtension = candidate.lowercased().hasSuffix(".txt")
        let base = hasTextExtension ? String(candidate.dropLast(4)) : candidate
        let suffix = hasTextExtension ? ".txt" : ""
        for number in 2...999 {
            let proposed = "\(base)_\(number)\(suffix)"
            if (try? pathPolicy.validateUniqueName(proposed, among: existingNames)) != nil {
                return proposed
            }
        }
        return candidate
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

    func isInManuscript(_ path: RelativeDocumentPath) -> Bool {
        let key = normalizedPathKey(path)
        let manuscriptKey = normalizedPathKey(BinderFixedCategory.manuscript.relativePath)
        return key == manuscriptKey || key.hasPrefix(manuscriptKey + "/")
    }

    func isReorderProtected(_ document: DocumentNode) -> Bool {
        isInManuscript(document.relativePath) || isInTrash(document.relativePath)
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

    func validVolumeNumbers(workspaceRoot: URL) throws -> [Int] {
        let manuscriptURL = try validatedURL(
            BinderFixedCategory.manuscript.relativePath,
            workspaceRoot: workspaceRoot
        )
        return try fileManager.contentsOfDirectory(
            at: manuscriptURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return ruleService.volumeNumber(fromStoredName: url.lastPathComponent)
        }
    }

    func chapterFileName(_ number: Int) -> String {
        let digits = number < 1_000 ? String(format: "%03d", number) : String(number)
        return digits + "화.txt"
    }

    func volumeTemporaryPath(for journal: BinderCommandJournal) -> RelativeDocumentPath {
        appending(
            ".writerpad-new-volume-\(journal.transactionID.uuidString.lowercased())",
            to: BinderFixedCategory.manuscript.relativePath
        )
    }

    func applyVolumeFiles(
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
        let temporary = try validatedURL(
            volumeTemporaryPath(for: journal),
            workspaceRoot: workspaceRoot
        )
        guard !fileManager.fileExists(atPath: temporary.path) else {
            throw BinderCommandError.destinationAlreadyExists(
                temporary.path,
                suggestedName: nil
            )
        }
        guard journal.newNodes.count == 26,
              journal.newNodes.first?.kind == .folder,
              journal.newNodes.dropFirst().allSatisfy({ $0.kind == .text })
        else {
            throw BinderCommandError.recoveryRequired(temporary.path)
        }

        try fileManager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        for (index, chapter) in journal.newNodes.dropFirst().enumerated() {
            let fileName = storedName(of: chapter.relativePath)
            try pathPolicy.validateName(fileName)
            let fileURL = temporary.appendingPathComponent(fileName)
            guard !fileManager.fileExists(atPath: fileURL.path) else {
                throw BinderCommandError.destinationAlreadyExists(fileURL.path, suggestedName: nil)
            }
            try Data().write(to: fileURL, options: [.atomic])
            try inject(.afterVolumeChapterFile(index + 1))
        }
        try fileManager.moveItem(at: temporary, to: destination)
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
