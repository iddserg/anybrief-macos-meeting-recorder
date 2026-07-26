import Darwin
import Foundation

/// Prevents multiple app instances from running concurrently.
final class SingleInstanceLock {
    enum LockError: Error, Equatable {
        case alreadyRunning
        case openFailed(path: String, errno: Int32)
    }

    let lockFileURL: URL
    private let fileDescriptor: Int32

    private init(lockFileURL: URL, fileDescriptor: Int32) {
        self.lockFileURL = lockFileURL
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func acquire(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> SingleInstanceLock {
        let appDirectoryURL = homeDirectoryURL.appendingPathComponent("anybrief", isDirectory: true)
        try fileManager.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)

        let lockFileURL = appDirectoryURL.appendingPathComponent(".app.lock", isDirectory: false)
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LockError.openFailed(path: lockFileURL.path, errno: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            close(descriptor)
            if lockErrno == EWOULDBLOCK {
                throw LockError.alreadyRunning
            }
            throw LockError.openFailed(path: lockFileURL.path, errno: lockErrno)
        }

        return SingleInstanceLock(lockFileURL: lockFileURL, fileDescriptor: descriptor)
    }
}
