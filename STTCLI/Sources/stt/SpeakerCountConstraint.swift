import FluidAudio
import Foundation

/// Exact-count compatibility fallback for cases where FluidAudio's VBx stage
/// creates the requested clusters but timeline reconstruction drops one.
enum SpeakerCountConstraint {
    static func apply(
        to result: DiarizationResult,
        exactCount: Int
    ) -> DiarizationResult {
        guard exactCount > 0, result.segments.count >= exactCount else {
            return result
        }

        let dimension = result.segments.first(where: { !$0.embedding.isEmpty })?.embedding.count ?? 0
        let validIndices = result.segments.indices.filter {
            result.segments[$0].embedding.count == dimension
        }
        guard dimension > 0, validIndices.count >= exactCount else {
            return result
        }

        let vectors = validIndices.map { normalized(result.segments[$0].embedding) }
        guard vectors.allSatisfy({ !$0.isEmpty }) else {
            return result
        }

        let assignments = cluster(vectors, count: exactCount)
        guard Set(assignments).count == exactCount else {
            return result
        }

        var assignmentBySegmentIndex = Dictionary(
            uniqueKeysWithValues: zip(validIndices, assignments)
        )
        var assignmentsByOriginalSpeaker: [String: [Int: Int]] = [:]
        for (index, assignment) in assignmentBySegmentIndex {
            assignmentsByOriginalSpeaker[
                result.segments[index].speakerId,
                default: [:]
            ][assignment, default: 0] += 1
        }
        let fallbackAssignments = assignmentsByOriginalSpeaker.mapValues { counts in
            counts.max {
                $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
            }?.key ?? 0
        }
        for index in result.segments.indices where assignmentBySegmentIndex[index] == nil {
            assignmentBySegmentIndex[index] =
                fallbackAssignments[result.segments[index].speakerId] ?? 0
        }

        let clusterOrder = (0..<exactCount).sorted {
            firstStart(
                for: $0,
                assignments: assignmentBySegmentIndex,
                segments: result.segments
            ) < firstStart(
                for: $1,
                assignments: assignmentBySegmentIndex,
                segments: result.segments
            )
        }
        let labels = Dictionary(
            uniqueKeysWithValues: clusterOrder.enumerated().map {
                ($0.element, String($0.offset + 1))
            }
        )
        let segments = result.segments.indices.map { index in
            let segment = result.segments[index]
            let cluster = assignmentBySegmentIndex[index] ?? 0
            return TimedSpeakerSegment(
                speakerId: labels[cluster] ?? "1",
                embedding: segment.embedding,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                qualityScore: segment.qualityScore
            )
        }
        return DiarizationResult(
            segments: segments,
            speakerDatabase: result.speakerDatabase,
            chunkEmbeddings: result.chunkEmbeddings,
            timings: result.timings
        )
    }

    private static func cluster(_ vectors: [[Float]], count: Int) -> [Int] {
        var centroids = initialCentroids(vectors, count: count)
        var assignments = [Int](repeating: 0, count: vectors.count)

        for _ in 0..<50 {
            let previous = assignments
            for index in vectors.indices {
                assignments[index] = nearestCentroid(
                    for: vectors[index],
                    centroids: centroids
                )
            }
            fillEmptyClusters(
                assignments: &assignments,
                vectors: vectors,
                centroids: centroids,
                count: count
            )
            centroids = recomputeCentroids(
                vectors: vectors,
                assignments: assignments,
                count: count
            )
            if assignments == previous {
                break
            }
        }
        return assignments
    }

    private static func initialCentroids(
        _ vectors: [[Float]],
        count: Int
    ) -> [[Float]] {
        var selected = [0]
        while selected.count < count {
            let next = vectors.indices
                .filter { !selected.contains($0) }
                .max {
                    minimumDistance(
                        from: vectors[$0],
                        to: selected.map { vectors[$0] }
                    ) < minimumDistance(
                        from: vectors[$1],
                        to: selected.map { vectors[$0] }
                    )
                } ?? selected.count
            selected.append(next)
        }
        return selected.map { vectors[$0] }
    }

    private static func fillEmptyClusters(
        assignments: inout [Int],
        vectors: [[Float]],
        centroids: [[Float]],
        count: Int
    ) {
        var clusterCounts = assignments.reduce(into: [Int: Int]()) {
            $0[$1, default: 0] += 1
        }
        for emptyCluster in 0..<count where clusterCounts[emptyCluster, default: 0] == 0 {
            let candidates = vectors.indices.filter {
                clusterCounts[assignments[$0], default: 0] > 1
            }
            guard let candidate = candidates.min(by: {
                cosine(vectors[$0], centroids[assignments[$0]])
                    < cosine(vectors[$1], centroids[assignments[$1]])
            }) else {
                continue
            }
            clusterCounts[assignments[candidate], default: 0] -= 1
            assignments[candidate] = emptyCluster
            clusterCounts[emptyCluster] = 1
        }
    }

    private static func recomputeCentroids(
        vectors: [[Float]],
        assignments: [Int],
        count: Int
    ) -> [[Float]] {
        var sums = Array(
            repeating: [Float](repeating: 0, count: vectors[0].count),
            count: count
        )
        for (vector, assignment) in zip(vectors, assignments) {
            for index in vector.indices {
                sums[assignment][index] += vector[index]
            }
        }
        return sums.indices.map { cluster in
            let centroid = normalized(sums[cluster])
            return centroid.isEmpty
                ? vectors[assignments.firstIndex(of: cluster) ?? 0]
                : centroid
        }
    }

    private static func nearestCentroid(
        for vector: [Float],
        centroids: [[Float]]
    ) -> Int {
        centroids.indices.max {
            cosine(vector, centroids[$0]) < cosine(vector, centroids[$1])
        } ?? 0
    }

    private static func minimumDistance(
        from vector: [Float],
        to centroids: [[Float]]
    ) -> Float {
        centroids.map { 1 - cosine(vector, $0) }.min() ?? 0
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else {
            return []
        }
        return vector.map { $0 / magnitude }
    }

    private static func firstStart(
        for cluster: Int,
        assignments: [Int: Int],
        segments: [TimedSpeakerSegment]
    ) -> Float {
        assignments.compactMap {
            $0.value == cluster ? segments[$0.key].startTimeSeconds : nil
        }.min() ?? .greatestFiniteMagnitude
    }
}
