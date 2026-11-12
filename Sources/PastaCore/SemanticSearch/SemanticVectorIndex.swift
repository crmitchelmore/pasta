import Accelerate
import Foundation

enum VectorMath {
    /// `vector` scaled to unit length, or `nil` when empty, zero or not finite.
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sumOfSquares.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vDSP.divide(vector, norm)
    }

    static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(from data: Data) -> [Float]? {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = data.copyBytes(to: buffer)
            initialized = count
        }
    }
}

/// In-memory matrix of unit vectors searched by brute-force cosine similarity.
///
/// A dense matrix-vector product over 10k × 512 floats takes about a
/// millisecond with Accelerate, so no approximate index is needed for
/// clipboard-sized histories.
struct SemanticVectorIndex: Sendable {
    struct Hit: Sendable, Equatable {
        let id: UUID
        let score: Float
    }

    private(set) var dimensions = 0
    private var ids: [UUID] = []
    private var positions: [UUID: Int] = [:]
    private var matrix: [Float] = []

    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool { positions[id] != nil }

    mutating func removeAll() {
        dimensions = 0
        ids.removeAll()
        positions.removeAll()
        matrix.removeAll()
    }

    /// Adds or replaces a unit vector. A vector of a different size from the
    /// existing ones resets the index, since they cannot be compared.
    mutating func upsert(id: UUID, vector: [Float]) {
        guard !vector.isEmpty else { return }
        if dimensions != vector.count {
            removeAll()
            dimensions = vector.count
        }
        if let position = positions[id] {
            matrix.replaceSubrange(position * dimensions..<(position + 1) * dimensions, with: vector)
        } else {
            positions[id] = ids.count
            ids.append(id)
            matrix.append(contentsOf: vector)
        }
    }

    mutating func remove(id: UUID) {
        guard let position = positions.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if position != last {
            let movedID = ids[last]
            ids[position] = movedID
            positions[movedID] = position
            for offset in 0..<dimensions {
                matrix[position * dimensions + offset] = matrix[last * dimensions + offset]
            }
        }
        ids.removeLast()
        matrix.removeLast(dimensions)
    }

    /// The `limit` most similar vectors to the unit vector `query`, best first.
    func search(_ query: [Float], limit: Int) -> [Hit] {
        guard limit > 0, !ids.isEmpty, query.count == dimensions else { return [] }
        var scores = [Float](repeating: 0, count: ids.count)
        matrix.withUnsafeBufferPointer { matrixBuffer in
            query.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { scoreBuffer in
                    vDSP_mmul(
                        matrixBuffer.baseAddress!, 1,
                        queryBuffer.baseAddress!, 1,
                        scoreBuffer.baseAddress!, 1,
                        vDSP_Length(ids.count), 1, vDSP_Length(dimensions)
                    )
                }
            }
        }
        let indices = scores.indices.sorted { scores[$0] > scores[$1] }.prefix(limit)
        return indices.map { Hit(id: ids[$0], score: scores[$0]) }
    }
}
