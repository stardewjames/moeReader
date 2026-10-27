import os

enum Signpost {
    static let reader = OSSignposter(subsystem: "com.moereader.MoeReader", category: "Reader")
}
