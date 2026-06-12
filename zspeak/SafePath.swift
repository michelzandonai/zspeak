import Foundation

enum SafePath {
    static func firstURL(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask = .userDomainMask
    ) -> URL {
        FileManager.default.urls(for: directory, in: domainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
