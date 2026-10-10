import Darwin
import Foundation

/// The daemon's scratch directories (the verified copy of the app, the copy of a profile): made by
/// mkdtemp, removed as root. 0.15.1's daemon read mkdtemp's result after the template array was
/// gone, got "" in the optimized build, copied the app to "/KillSwitch.app" and on that failure
/// removed "/" (the read-only system volume saved it). So the path is read inside the buffer's
/// scope, and nothing but such a directory is ever removed.
enum PrivateDirectory {
    static let prefix = "killswitch."

    /// A fresh 0700 directory `<temporary>/killswitch.XXXXXX`.
    static func make(in temporary: String = NSTemporaryDirectory()) -> URL? {
        var template = Array((temporary as NSString).appendingPathComponent(prefix + "XXXXXX").utf8CString)
        let path: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path, isRemovable(path, temporary: temporary) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Only what `make` gives: an absolute path, a real directory (no symlink) right inside the
    /// temporary directory, named `killswitch.` and something. Never "/", "" or anything else.
    static func isRemovable(_ path: String, temporary: String = NSTemporaryDirectory()) -> Bool {
        guard path.hasPrefix("/"), !temporary.isEmpty, temporary.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = URL(fileURLWithPath: temporary, isDirectory: true).standardizedFileURL
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.count > prefix.count, !name.contains("/"),
              url.deletingLastPathComponent().path == parent.path, parent.path != "/" else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes a directory `make` gave; anything else is left alone (false).
    @discardableResult
    static func remove(_ url: URL, temporary: String = NSTemporaryDirectory()) -> Bool {
        guard isRemovable(url.path, temporary: temporary) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
