import Foundation

public enum UsageHistorySampler {
    public static let maximumPointCount = 480

    public static func displaySamples(
        from samples: [QuotaSample],
        maximumPointCount: Int = maximumPointCount
    ) -> [QuotaSample] {
        guard samples.count > maximumPointCount else {
            return samples
        }
        guard maximumPointCount > 1 else {
            return samples.last.map { [$0] } ?? []
        }

        let lastIndex = samples.count - 1
        let step = Double(lastIndex) / Double(maximumPointCount - 1)
        var sampled: [QuotaSample] = []
        sampled.reserveCapacity(maximumPointCount)

        var previousIndex = -1
        for outputIndex in 0..<maximumPointCount {
            let sourceIndex = min(lastIndex, Int((Double(outputIndex) * step).rounded()))
            guard sourceIndex != previousIndex else {
                continue
            }
            sampled.append(samples[sourceIndex])
            previousIndex = sourceIndex
        }

        if sampled.last != samples[lastIndex] {
            if sampled.count >= maximumPointCount {
                sampled[sampled.count - 1] = samples[lastIndex]
            } else {
                sampled.append(samples[lastIndex])
            }
        }

        return sampled
    }
}
