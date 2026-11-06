#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A value behind a lock, for caches a library caller could reach from several threads (the
/// engine itself runs on one). WebAssembly here has no threads, so there it's a plain box.
/// `Synchronization.Mutex` would do this, but needs macOS 15 and the package supports 13.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    #endif

    init(_ value: Value) {
        self.value = value
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
        #endif
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
        #endif
    }

    /// Runs `body` with the value, holding the lock.
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        #endif
        return try body(&value)
    }
}
