import Foundation
import Darwin

// No Auth client or token access: identity and expiration are an explicit session double.
final class ABSessionDouble {
    struct Snapshot { let id: String, generation: Int, expiresUTCMS: Int }
    private let lock = NSLock()
    private var id: String, generation: Int, expiry: Int
    init(id: String = "synthetic-runtime-session",expiresUTCMS: Int,generation:Int = 0) { self.id = id; expiry = expiresUTCMS;self.generation = generation }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return .init(id:id,generation:generation,expiresUTCMS:expiry) }
    func replace(id: String? = nil,expiresUTCMS: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        generation = try abAdd(generation,1)
        if let id { self.id = id }; if let expiresUTCMS { expiry = expiresUTCMS }
    }
}
final class ABRuntimeClock {
    struct Sample { let utcMS: Int, monoMS: Int }
    private let lock = NSLock()
    private var manual: Sample?
    let isSystem: Bool
    init() { manual = nil; isSystem = true }
    init(utcMS: Int,monoMS: Int) { manual = .init(utcMS:utcMS,monoMS:monoMS); isSystem = false }
    func sample() throws -> Sample {
        lock.lock(); defer { lock.unlock() }
        if let manual { try abInteger(manual.utcMS); try abInteger(manual.monoMS); return manual }
        var scale = mach_timebase_info_data_t()
        try abNeed(mach_timebase_info(&scale) == KERN_SUCCESS && scale.denom > 0,.arithmetic)
        // Continuous time includes sleep (local SDK mach_time.h); convert without UInt64 overflow.
        let ticks = mach_continuous_time(), denominator = UInt64(scale.denom)*1_000_000
        let (whole,overflow) = (ticks/denominator).multipliedReportingOverflow(by:UInt64(scale.numer))
        let (fraction,overflow2) = (ticks%denominator).multipliedReportingOverflow(by:UInt64(scale.numer))
        let (ms,overflow3) = whole.addingReportingOverflow(fraction/denominator)
        let utc = (Date().timeIntervalSince1970*1000).rounded(.down)
        try abNeed(!overflow && !overflow2 && !overflow3 && ms <= 9_007_199_254_740_991 && utc.isFinite && utc >= 0 && utc <= 9_007_199_254_740_991,.arithmetic)
        return .init(utcMS:Int(utc),monoMS:Int(ms))
    }
    func advance(_ delta: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try abInteger(delta)
        guard let current = manual else { try abNeed(delta == 0,.policy); return }
        manual = try .init(utcMS:abAdd(current.utcMS,delta),monoMS:abAdd(current.monoMS,delta))
    }
    func setForTest(utcMS: Int,monoMS: Int) throws {
        lock.lock(); defer { lock.unlock() }; try abNeed(!isSystem,.policy)
        manual = .init(utcMS:utcMS,monoMS:monoMS)
    }
}
