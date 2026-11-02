import Foundation

/// Codec for the existing ISO-8601 JSONL history format. Use this codec when sharing files between applications.
public enum UsageHistoryCodec {
    public enum MalformedLines: Sendable { case reject, skip }

    public static func encode(_ samples: [QuotaSample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try samples.reduce(into: Data()) { data, sample in
            data.append(try encoder.encode(sample))
            data.append(0x0A)
        }
    }

    public static func decode(_ data: Data, malformedLines: MalformedLines = .reject) throws -> [QuotaSample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).compactMap { line in
            if malformedLines == .skip { return try? decoder.decode(QuotaSample.self, from: Data(line)) }
            return try decoder.decode(QuotaSample.self, from: Data(line))
        }
    }
}
