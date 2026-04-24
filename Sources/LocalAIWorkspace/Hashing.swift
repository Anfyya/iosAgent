import Foundation

public enum StableHasher {
    public static func fnv1a64(data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001B3

        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        return String(format: "%016llx", hash)
    }

    public static func fnv1a64(string: String) -> String {
        fnv1a64(data: Data(string.utf8))
    }
}
