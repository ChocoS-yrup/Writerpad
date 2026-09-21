import Foundation

struct ReceivePromotionDocumentReview: Equatable, Sendable {
    let sourceDocumentID: UUID
    let sourceName: String
    let sourceBodyHash: ContentHash
    let editableRevision: Int
    let editableBodyHash: ContentHash
    let byteCount: Int
    let payloadPath: RelativeDocumentPath
}

/// A validated, read-only view of one Receive Boundary package.
/// The package must be read and fingerprinted again before a promotion writes.
struct ReceivePromotionReport: Equatable, Identifiable, Sendable {
    var id: UUID { packageID }

    let sourceSelectionURL: URL
    let packageID: UUID
    let producerBundleID: String
    let sourceLocalID: UUID
    let sourceRunID: UUID
    let sourceFolderName: String
    let editableIdentityHash: ContentHash
    let editableWorkspaceHash: ContentHash
    let sourceKey: ContentHash
    let packageFingerprint: ContentHash
    let suggestedProjectName: String
    let documents: [ReceivePromotionDocumentReview]

    var totalBytes: Int {
        documents.reduce(0) { $0 + $1.byteCount }
    }
}

/// Transaction-only materialized body. UI code should use ReceivePromotionReport.
struct ReceivePromotionPayloadDocument: Equatable, Sendable {
    let review: ReceivePromotionDocumentReview
    let data: Data
}

struct ReceivePromotionValidatedPackage: Equatable, Sendable {
    let report: ReceivePromotionReport
    let documents: [ReceivePromotionPayloadDocument]
}

struct ReceivePromotionDocumentMapping: Equatable, Sendable {
    let sourceDocumentID: UUID
    let writerPadDocumentID: DocumentID
}

struct ReceivePromotionResult: Equatable, Sendable {
    let transactionID: UUID
    let project: ManagedProject
    let sourceKey: ContentHash
    let packageFingerprint: ContentHash
    let documentMappings: [ReceivePromotionDocumentMapping]
    let wasAlreadyCompleted: Bool
}
