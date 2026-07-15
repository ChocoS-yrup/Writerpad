import CryptoKit
import Foundation

struct SHA256ContentHasher: ContentHashing {
    func sha256(for data: Data) -> ContentHash {
        let hexadecimal = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        // SHA256의 결과는 항상 유효한 64자리 16진수다.
        return ContentHash(rawValue: hexadecimal)!
    }
}
