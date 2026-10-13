import Foundation

/// Preenche silêncio e copia a fala uma única vez, preservando cada bit do sinal.
enum AudioSamplePadding {
    static func addingSilence(
        to samples: [Float], leading: Int = 0, trailing: Int = 0,
        minimumCount: Int = 0
    ) -> [Float] {
        let leading = max(0, leading)
        let trailing = max(0, trailing)
        let count = max(minimumCount, samples.count + leading + trailing)
        guard count > samples.count else { return samples }
        return samples.withUnsafeBufferPointer { source in
            padded(source, leading: leading, count: count)
        }
    }

    /// O commit do preview usa um range do áudio; evita uma cópia intermediária.
    static func addingSilence(
        to samples: ArraySlice<Float>, leading: Int = 0, trailing: Int = 0,
        minimumCount: Int = 0
    ) -> [Float] {
        let leading = max(0, leading)
        let count = max(minimumCount, samples.count + leading + max(0, trailing))
        guard count > 0 else { return [] }
        return samples.withUnsafeBufferPointer { source in
            padded(source, leading: leading, count: count)
        }
    }

    private static func padded(_ source: UnsafeBufferPointer<Float>, leading: Int, count: Int) -> [Float] {
        return [Float](unsafeUninitializedCapacity: count) { destination, initializedCount in
            let base = destination.baseAddress!
            base.initialize(repeating: 0, count: leading)
            if let sourceBase = source.baseAddress {
                base.advanced(by: leading).initialize(from: sourceBase, count: source.count)
            }
            let end = leading + source.count
            base.advanced(by: end).initialize(repeating: 0, count: count - end)
            initializedCount = count
        }
    }
}
