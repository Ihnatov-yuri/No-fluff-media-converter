import Foundation
import VideoCompressorCore

enum JobStatus: Equatable {
    case probing
    case ready
    case running
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .probing:
            return "Reading"
        case .ready:
            return "Ready"
        case .running:
            return "Compressing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var canRun: Bool {
        switch self {
        case .ready, .failed, .cancelled:
            return true
        case .probing, .running, .completed:
            return false
        }
    }
}

enum PreviewStatus: Equatable {
    case notRendered
    case rendering
    case ready
    case failed

    var displayName: String {
        switch self {
        case .notRendered:
            return "Not Rendered"
        case .rendering:
            return "Rendering"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }
}

enum ComparisonStage: String, Equatable {
    case before
    case after
}

struct ComparisonRequest: Identifiable, Equatable {
    var jobID: UUID
    var stage: ComparisonStage

    var id: String {
        "\(stage.rawValue)-\(jobID.uuidString)"
    }
}

struct ComparisonFrame: Identifiable, Equatable, Sendable {
    let id: UUID
    var originalURL: URL
    var compressedURL: URL
    var timestamp: Double

    init(originalURL: URL, compressedURL: URL, timestamp: Double) {
        self.id = UUID()
        self.originalURL = originalURL
        self.compressedURL = compressedURL
        self.timestamp = timestamp
    }
}

struct CompressionJob: Identifiable, Equatable {
    let id: UUID
    let inputURL: URL
    var outputURL: URL
    var metadata: MediaMetadata?
    var outputMetadata: MediaMetadata?
    var originalSizeBytes: Int64
    var outputSizeBytes: Int64?
    var appliedSettings: CompressionSettings?
    var previewSettings: CompressionSettings?
    var status: JobStatus
    var progress: Double
    var errorMessage: String?
    var previewURL: URL?
    var previewMetadata: MediaMetadata?
    var previewSizeBytes: Int64?
    var previewStatus: PreviewStatus
    var previewProgress: Double
    var previewErrorMessage: String?
    var previewFrames: [ComparisonFrame]
    var outputFrames: [ComparisonFrame]

    init(inputURL: URL, outputURL: URL, originalSizeBytes: Int64) {
        self.id = UUID()
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.metadata = nil
        self.outputMetadata = nil
        self.originalSizeBytes = originalSizeBytes
        self.outputSizeBytes = nil
        self.appliedSettings = nil
        self.previewSettings = nil
        self.status = .probing
        self.progress = 0
        self.errorMessage = nil
        self.previewURL = nil
        self.previewMetadata = nil
        self.previewSizeBytes = nil
        self.previewStatus = .notRendered
        self.previewProgress = 0
        self.previewErrorMessage = nil
        self.previewFrames = []
        self.outputFrames = []
    }
}
