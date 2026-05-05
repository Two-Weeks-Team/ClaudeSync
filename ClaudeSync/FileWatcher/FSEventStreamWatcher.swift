import Foundation
import CoreServices

/// Single FSEvents stream wrapped as an `AsyncStream<FSEvent>`.
///
/// The C `FSEventStreamCallback` cannot capture Swift state, so the context
/// pointer holds an `Unmanaged<CallbackBox>` carrying the AsyncStream
/// continuation. The box is retained for the lifetime of the stream and
/// released in `stop()`.
///
/// Reference: TECHNICAL_SPEC §11 (FSEvents Configuration), lines 1845-1893.
public final class FSEventStreamWatcher: @unchecked Sendable {

    public struct FSEvent: Sendable, Equatable {
        public let path: String
        public let flags: UInt32
        public let id: UInt64

        public var isCreated:  Bool { (flags & UInt32(kFSEventStreamEventFlagItemCreated))  != 0 }
        public var isModified: Bool { (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0 }
        public var isRemoved:  Bool { (flags & UInt32(kFSEventStreamEventFlagItemRemoved))  != 0 }
        public var isRenamed:  Bool { (flags & UInt32(kFSEventStreamEventFlagItemRenamed))  != 0 }
        public var isFile:     Bool { (flags & UInt32(kFSEventStreamEventFlagItemIsFile))   != 0 }
    }

    /// Callback context passed through the C boundary.
    private final class CallbackBox {
        let continuation: AsyncStream<FSEvent>.Continuation
        init(_ c: AsyncStream<FSEvent>.Continuation) { self.continuation = c }
    }

    private var streamRef: FSEventStreamRef?
    private var box: CallbackBox?
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "claudesync.fseventstream",
                                                    qos: .userInitiated)) {
        self.queue = queue
    }

    /// Start a new FSEvents stream over the given paths. Returns the AsyncStream
    /// of events plus a stop closure (called automatically when the AsyncStream
    /// is terminated).
    @discardableResult
    public func start(
        paths: [String],
        latency: CFTimeInterval = 0.3,
        sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    ) -> AsyncStream<FSEvent> {
        // If we're already running, tear down first.
        stop()

        return AsyncStream<FSEvent> { continuation in
            let box = CallbackBox(continuation)
            self.box = box

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
            )

            let cfPaths = paths as CFArray
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                cfPaths,
                sinceWhen,
                latency,
                flags
            ) else {
                continuation.finish()
                return
            }

            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
            self.streamRef = stream

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        if let s = streamRef {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            streamRef = nil
        }
        box?.continuation.finish()
        box = nil
    }

    deinit { stop() }

    // MARK: - C callback

    private static let callback: FSEventStreamCallback = { (
        _ streamRef: ConstFSEventStreamRef,
        clientCallBackInfo: UnsafeMutableRawPointer?,
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIds: UnsafePointer<FSEventStreamEventId>
    ) in
        guard let info = clientCallBackInfo else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()

        // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is CFArray of CFString.
        let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        guard count == numEvents else { return }

        for i in 0..<count {
            let cfStr = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, i), to: CFString.self)
            let path = cfStr as String
            let event = FSEvent(
                path: path,
                flags: eventFlags[i],
                id: eventIds[i]
            )
            box.continuation.yield(event)
        }
    }
}
