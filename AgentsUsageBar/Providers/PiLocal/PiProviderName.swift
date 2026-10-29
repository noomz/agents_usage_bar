import Foundation

/// Branded Pi `providers` key (`DRM-SWAP`, `llama.cpp`, `ollama`).
struct PiProviderName: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}
