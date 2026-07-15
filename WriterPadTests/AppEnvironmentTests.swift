import SwiftData
import XCTest
@testable import WriterPad

final class AppEnvironmentTests: XCTestCase {
    @MainActor
    func testTestingEnvironmentUsesWritableInMemoryMetadata() throws {
        let environment = try AppEnvironment.testing()
        let record = BootstrapRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        environment.modelContainer.mainContext.insert(record)
        try environment.modelContainer.mainContext.save()

        let records = try environment.modelContainer.mainContext.fetch(
            FetchDescriptor<BootstrapRecord>()
        )
        XCTAssertEqual(records.map(\.id), [record.id])
    }

    func testNoOpFutureNotifierAcceptsLocalEvents() async {
        await NoOpFutureChangeNotifier().record(.appLaunched)
    }
}
