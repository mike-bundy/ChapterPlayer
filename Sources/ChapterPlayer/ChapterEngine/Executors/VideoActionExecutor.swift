//
//  VideoActionExecutor.swift
//  SharedVisions
//
//  Bridges StepAction video commands to VideoPlaybackManager.
//

import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "VideoActionExecutor"
)

// MARK: - Protocol

@MainActor
public protocol VideoActionExecutorProtocol {
    func play(_ action: VideoAction)
    func prepare(_ action: VideoAction)
    func stop(channel: String)
    func seek(channel: String, to time: TimeInterval)
    func pauseAll()
    func resumeAll()
    func stopAll()
}

// MARK: - Implementation

@MainActor
public final class VideoActionExecutor: VideoActionExecutorProtocol {

    public let videoManager: VideoPlaybackManager

    public init(videoManager: VideoPlaybackManager) {
        self.videoManager = videoManager
    }

    public func play(_ action: VideoAction) {
        videoManager.play(action: action)
    }

    public func prepare(_ action: VideoAction) {
        videoManager.prepare(action: action)
    }

    public func stop(channel: String) {
        videoManager.stop(channel: channel)
    }

    public func seek(channel: String, to time: TimeInterval) {
        videoManager.seek(channel: channel, to: time)
    }

    public func pauseAll() {
        videoManager.pauseAll()
    }

    public func resumeAll() {
        videoManager.resumeAll()
    }

    public func stopAll() {
        videoManager.stopAll()
    }
}
