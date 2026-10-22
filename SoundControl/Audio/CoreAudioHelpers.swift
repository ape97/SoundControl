import CoreAudio
import Foundation

/// Thin wrapper around Core Audio's C API: read, write and observe properties.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T {
        var a = addr
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? result : value
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }

    static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Observes a property; the block runs on the main queue. The return value removes the observer.
    @discardableResult
    static func observe(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                        _ handler: @escaping () -> Void) -> () -> Void {
        var a = addr
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &a, DispatchQueue.main, block)
        guard status == noErr else { return {} }
        return {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
    }
}
