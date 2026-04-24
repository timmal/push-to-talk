import Foundation
import WhisperKit

public final class ModelManager {
    public static let shared = ModelManager()
    private init() {}

    public func managedDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/models")
    }

    public func downloadCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/hf-cache")
    }

    public func macWhisperDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml")
    }

    /// Default download base used by `swift-transformers` / WhisperKit when no
    /// `downloadBase` is supplied. Other WhisperKit-powered apps (and older
    /// builds of this app) drop CoreML models here, so we probe it to avoid
    /// re-downloading gigabytes the user already has.
    public func externalWhisperKitDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    public func locateModel(_ id: WhisperModelID) -> URL? {
        let fm = FileManager.default
        let managed = managedDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: managed.path) { return managed }
        let macWhisper = macWhisperDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: macWhisper.path) { return macWhisper }
        let external = externalWhisperKitDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: external.path), fm.isReadableFile(atPath: external.path) {
            return external
        }
        return nil
    }

    public func download(_ id: WhisperModelID,
                         progress: @escaping (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: managedDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadCacheDirectory(), withIntermediateDirectories: true)
        let downloaded = try await WhisperKit.download(
            variant: id.rawValue,
            downloadBase: downloadCacheDirectory(),
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in progress(p.fractionCompleted) }
        )
        let dst = managedDirectory().appendingPathComponent(id.rawValue)
        if downloaded.path != dst.path {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: downloaded, to: dst)
            if !FileManager.default.fileExists(atPath: dst.path) { return downloaded }
        }
        return dst
    }
}
