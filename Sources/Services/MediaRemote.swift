import AppKit
import Foundation

/// Thin wrapper over the system now-playing service that Control Center uses.
/// Everything degrades to "unavailable" when the framework can't be loaded.
final class MediaRemote {
    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    static let shared = MediaRemote()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendFn = @convention(c) (Int32, AnyObject?) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private let getInfo: GetInfoFn?
    private let sendCommand: SendFn?
    private let getPID: GetPIDFn?
    private let isPlayingFn: IsPlayingFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            getInfo = nil; sendCommand = nil; getPID = nil; isPlayingFn = nil
            return
        }
        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        getInfo = symbol("MRMediaRemoteGetNowPlayingInfo")
        sendCommand = symbol("MRMediaRemoteSendCommand")
        getPID = symbol("MRMediaRemoteGetNowPlayingApplicationPID")
        isPlayingFn = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
    }

    var isAvailable: Bool { getInfo != nil && sendCommand != nil }

    /// Current track metadata, or nil when nothing is playing.
    func nowPlaying(timeout: TimeInterval = 1.2) -> [String: Any]? {
        guard let getInfo else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        getInfo(DispatchQueue.global(qos: .userInitiated)) { info in
            result = info
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        guard let result, !result.isEmpty else { return nil }
        return result
    }

    func isPlaying(timeout: TimeInterval = 0.6) -> Bool {
        guard let isPlayingFn else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var playing = false
        isPlayingFn(DispatchQueue.global(qos: .userInitiated)) { value in
            playing = value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return playing
    }

    func sourceApplication() -> NSRunningApplication? {
        guard let getPID else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var pid: Int32 = 0
        getPID(DispatchQueue.global(qos: .userInitiated)) { value in
            pid = value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.6)
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let sendCommand else { return false }
        sendCommand(command.rawValue, nil)
        return true
    }
}

enum MediaKeys {
    static let title = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
    static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let artwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let rate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
}
