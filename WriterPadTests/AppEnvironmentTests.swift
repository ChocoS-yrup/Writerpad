import Foundation
import XCTest
@testable import WriterPad

final class AppEnvironmentTests: XCTestCase {
    @MainActor
    func testTestingEnvironmentUsesWritableInMemoryMetadata() async throws {
        let environment = try AppEnvironment.testing()
        let project = Project(
            id: ProjectID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            name: "환경 테스트",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )

        try await environment.projectRepository.save(project)
        let projects = try await environment.projectRepository.projects()

        XCTAssertEqual(projects, [project])
    }

    func testNoOpFutureNotifierAcceptsLocalEvents() async {
        await NoOpFutureChangeNotifier().record(.appLaunched)
    }
}
