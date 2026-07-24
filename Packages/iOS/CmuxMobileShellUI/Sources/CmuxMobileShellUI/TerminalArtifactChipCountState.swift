import Foundation

/// Coalesces session-count requests while preserving the local visible-count fallback.
struct TerminalArtifactChipCountState: Sendable {
    struct Request: Sendable, Equatable {
        let stateGeneration: UInt64
        let surfaceGeneration: UInt64
        let localCount: Int
    }

    struct Report: Sendable, Equatable {
        let count: Int
        let surfaceGeneration: UInt64
    }

    enum TriggerAction: Sendable, Equatable {
        case none
        case report(Report)
        case request(Request)
        /// Report a provisional count now and refine it with a session scan.
        ///
        /// The provisional report is what keeps the chip honest on a busy
        /// terminal: a session scan only survives if no output arrives while
        /// its RPC is in flight, so waiting for it systematically drops the
        /// positive counts (scanned right before the next output burst) while
        /// zero counts (scanned in quiet pauses) get through, parking the
        /// chip on zero and flickering it. The local count needs no RPC.
        case reportAndRequest(Report, Request)
    }

    enum CompletionOutcome: Sendable, Equatable {
        case reported(Report)
        case droppedForSurfaceGenerationMismatch
        case stale
    }

    struct Completion: Sendable, Equatable {
        let outcome: CompletionOutcome
        let nextRequest: Request?

        static let stale = Completion(outcome: .stale, nextRequest: nil)
    }

    private struct Pending: Sendable, Equatable {
        let surfaceGeneration: UInt64
        let localCount: Int
    }

    private var stateGeneration: UInt64 = 0
    private var inFlight: Request?
    private var trailing: Pending?
    private var consecutiveRearmCount = 0
    /// Last successful gallery total (or positive legacy session total), held
    /// across transient scan failures so
    /// the chip does not regress to the viewport-only count (which oscillates
    /// while output streams) whenever one RPC drops.
    private var lastAuthoritativeTotal: Int?

    static let maxConsecutiveRearms = 3

    mutating func reset() {
        stateGeneration &+= 1
        inFlight = nil
        trailing = nil
        consecutiveRearmCount = 0
        lastAuthoritativeTotal = nil
    }

    mutating func trigger(
        localCount: Int,
        surfaceGeneration: UInt64,
        supportsSessionCount: Bool
    ) -> TriggerAction {
        consecutiveRearmCount = 0
        guard supportsSessionCount else {
            return .report(Report(count: localCount, surfaceGeneration: surfaceGeneration))
        }
        let provisional = Report(
            count: displayCount(forLocalCount: localCount),
            surfaceGeneration: surfaceGeneration
        )
        let pending = Pending(surfaceGeneration: surfaceGeneration, localCount: localCount)
        guard inFlight == nil else {
            trailing = pending
            return .report(provisional)
        }
        let request = makeRequest(pending)
        inFlight = request
        return .reportAndRequest(provisional, request)
    }

    /// The count the chip should show for a fresh local scan: the last known
    /// authoritative total wins when one exists, the viewport-only count
    /// otherwise.
    private func displayCount(forLocalCount localCount: Int) -> Int {
        if let lastAuthoritativeTotal {
            return lastAuthoritativeTotal
        }
        return localCount
    }

    mutating func complete(
        _ request: Request,
        galleryRowTotal: Int? = nil,
        sessionTotal: Int?,
        currentSurfaceGeneration: UInt64,
        freshestLocalCount: Int
    ) -> Completion {
        guard request.stateGeneration == stateGeneration,
              inFlight == request else {
            return .stale
        }
        inFlight = nil
        if let galleryRowTotal {
            lastAuthoritativeTotal = galleryRowTotal
        } else if let sessionTotal {
            // Preserve the old-Mac behavior exactly: positive Session totals
            // win, while zero falls back to the local viewport count.
            lastAuthoritativeTotal = sessionTotal > 0 ? sessionTotal : nil
        }

        let outcome: CompletionOutcome
        if request.surfaceGeneration == currentSurfaceGeneration {
            outcome = .reported(Report(
                count: displayCount(forLocalCount: request.localCount),
                surfaceGeneration: request.surfaceGeneration
            ))
            consecutiveRearmCount = 0
        } else {
            outcome = .droppedForSurfaceGenerationMismatch
        }

        if let trailing {
            self.trailing = nil
            if trailing.surfaceGeneration == currentSurfaceGeneration {
                let nextRequest = makeRequest(trailing)
                inFlight = nextRequest
                return Completion(outcome: outcome, nextRequest: nextRequest)
            }
        }

        guard outcome == .droppedForSurfaceGenerationMismatch,
              consecutiveRearmCount < Self.maxConsecutiveRearms else {
            return Completion(outcome: outcome, nextRequest: nil)
        }
        consecutiveRearmCount += 1
        let nextRequest = makeRequest(Pending(
            surfaceGeneration: currentSurfaceGeneration,
            localCount: freshestLocalCount
        ))
        inFlight = nextRequest
        return Completion(outcome: outcome, nextRequest: nextRequest)
    }

    private func makeRequest(_ pending: Pending) -> Request {
        Request(
            stateGeneration: stateGeneration,
            surfaceGeneration: pending.surfaceGeneration,
            localCount: pending.localCount
        )
    }
}
