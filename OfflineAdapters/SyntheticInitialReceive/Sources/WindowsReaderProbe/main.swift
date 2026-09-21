import Foundation
import SyntheticInitialReceive

// Host-only retained input review. No import of launchers, transport, app or credentials.
do {
    guard CommandLine.arguments.count == 2 else { throw WindowsReaderError.file }
    let url = URL(fileURLWithPath:CommandLine.arguments[1])
    let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          let bytes = attrs[.size] as? NSNumber, bytes.intValue <= 48*1024*1024 else { throw WindowsReaderError.file }
    let data = try Data(contentsOf:url)
    let report = try WindowsHandoffReader.review(portable:data,expected:.retainedSeptember14())
    print(String(decoding:try canonical(report),as:UTF8.self))
} catch {
    let code = (error as? WindowsReaderError)?.rawValue ?? "read_failed"
    print("{\"status\":\"blocked\",\"code\":\"\(code)\"}")
    exit(1)
}
