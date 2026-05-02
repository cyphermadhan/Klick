import Foundation

/// Reference-type single-value container used to carry mutable local state
/// into AVAudioConverter's `@Sendable` input block without triggering
/// Swift 6 "capture of var" warnings. The converter invokes its block
/// synchronously on the caller's thread, so shared mutable access is safe.
final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
