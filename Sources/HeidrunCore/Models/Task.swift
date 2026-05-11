import Foundation

/// An in-flight Hotline transaction the client is tracking.
///
/// Replaces `HeiTaskObject` from the original framework. Named `HotlineTask`
/// rather than `Task` to avoid shadowing `_Concurrency.Task` for callers
/// that `import Heidrun`.
public struct HotlineTask: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case pending
        case inFlight
        case completed
        case failed(errorID: UInt32)
    }

    public var taskNumber: UInt32
    public var transactionType: TransactionType
    public var date: Date
    public var status: Status

    /// Encoded payload bytes assembled into the request packet.
    public var data: Data

    public init(
        taskNumber: UInt32,
        transactionType: TransactionType,
        date: Date = Date(),
        status: Status = .pending,
        data: Data = Data()
    ) {
        self.taskNumber = taskNumber
        self.transactionType = transactionType
        self.date = date
        self.status = status
        self.data = data
    }

    public var id: UInt32 { taskNumber }
}
