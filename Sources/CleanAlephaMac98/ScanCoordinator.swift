import Foundation

/// Runs independent scan stages with **bounded** concurrency and streams each result back the
/// moment it finishes. Replaces the old "one `Background.run` at a time + `Thread.sleep` between
/// stages" model: the concurrency cap (not sleeps) is what keeps the Mac from melting, while
/// overlapping the mostly-I/O stages makes a Smart scan noticeably faster.
enum ScanCoordinator {
    /// Sensible default: use the machine but leave headroom. Scans are I/O-bound, so a handful of
    /// concurrent stages saturates the disk without pinning every core.
    static var defaultConcurrency: Int {
        max(2, min(ProcessInfo.processInfo.activeProcessorCount, 4))
    }

    /// Maps `work` over `inputs` at up to `maxConcurrency` in flight, yielding outputs in
    /// **completion order**. The producer runs at `.utility` QoS and is cancelled when the consumer
    /// stops iterating (the stream terminates).
    static func stream<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrency: Int = defaultConcurrency,
        work: @escaping @Sendable (Input) -> Output
    ) -> AsyncStream<Output> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .utility) {
                await withTaskGroup(of: Output.self) { group in
                    let limit = max(1, min(maxConcurrency, inputs.count))
                    var next = 0

                    func addNext() {
                        guard next < inputs.count else { return }
                        let input = inputs[next]
                        next += 1
                        group.addTask { work(input) }
                    }

                    for _ in 0..<limit { addNext() }

                    while let output = await group.next() {
                        if Task.isCancelled { break }
                        continuation.yield(output)
                        addNext()
                    }
                    group.cancelAll()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
