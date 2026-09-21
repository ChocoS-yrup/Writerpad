import Foundation

/// Shared host/iOS work boundary. Result publication requires the same live lease.
struct WindowsReaderWork {
    let lease: BoundaryLease
    func review(portable: Data,expected: WindowsHandoffExpectation) throws -> WindowsHandoffReview {
        try lease.check()
        let result = try WindowsHandoffReader.review(portable:portable,expected:expected,checkpoint:lease.check)
        try lease.check(); return result
    }
    func readLocalFile(_ url: URL) throws -> Data {
        try lease.check()
        guard url.isFileURL else { throw WindowsReaderError.file }
        // Do not request an iCloud download. This worker contains no provider/network API.
        if try url.resourceValues(forKeys:[.isUbiquitousItemKey]).isUbiquitousItem == true { throw WindowsReaderError.file }
        let bytes = try SafeFiles.read(url,limit:48*1024*1024)
        try lease.check(); return bytes
    }
    func publish(_ report: WindowsHandoffReview) throws -> WindowsHandoffReview { try lease.check(); return report }
}
