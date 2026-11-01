import Foundation
import IOKit.hid

/// Reads the controller home button straight from HID reports.
///
/// macOS consumes the home button for its own action (opening Games / Apple
/// Arcade) before GameController delivers it, even with the system gesture
/// disabled, whenever Spaceman isn't frontmost — which is always the case in a
/// game. The raw reports still carry it, so this watches them (opened
/// without seizing, so GameController and games keep working).
///
/// - Sony (DualSense, DualSense Edge, DualShock 4): the PS bit is decoded from
///   the input report, USB and Bluetooth layouts.
/// - Anything exposing the standard Consumer "AC Home" usage (Xbox over
///   Bluetooth) is picked up as an element value.
final class LoungeHIDHome {

    private let onHome: () -> Void
    private var manager: IOHIDManager?
    /// Last PS-bit state per device, for edge detection.
    private var pressed: [UnsafeMutableRawPointer: Bool] = [:]

    init(onHome: @escaping () -> Void) {
        self.onHome = onHome
    }

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, length in
            guard let context, let sender else { return }
            Unmanaged<LoungeHIDHome>.fromOpaque(context).takeUnretainedValue()
                .report(device: sender, id: reportID, bytes: report, length: length)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<LoungeHIDHome>.fromOpaque(context).takeUnretainedValue().value(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        loungeLog.info("HID home monitor open: \(result == kIOReturnSuccess ? "ok" : String(result), privacy: .public)")
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func report(device: UnsafeMutableRawPointer, id: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let hid = Unmanaged<IOHIDDevice>.fromOpaque(device).takeUnretainedValue()
        guard intProperty(hid, kIOHIDVendorIDKey) == 0x054C else { return }
        let product = intProperty(hid, kIOHIDProductIDKey)
        let data = UnsafeBufferPointer(start: bytes, count: length)
        guard let index = Self.psByteIndex(product: product, reportID: data.first ?? UInt8(id)),
              data.count > index else { return }
        edge(device, isDown: data[index] & 0x01 != 0)
    }

    /// Where the PS bit (bit 0) lives, counting the report-ID byte as 0.
    static func psByteIndex(product: Int, reportID: UInt8) -> Int? {
        let dualSense = [0x0CE6, 0x0DF2].contains(product)
        let dualShock4 = [0x05C4, 0x09CC, 0x0BA0].contains(product)
        switch (reportID, dualSense, dualShock4) {
        case (0x01, true, _): return 10   // DualSense USB / BT simple
        case (0x31, true, _): return 11   // DualSense BT extended
        case (0x01, _, true): return 7    // DualShock 4 USB / BT simple
        case (0x11, _, true): return 9    // DualShock 4 BT extended
        default: return nil
        }
    }

    private func value(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_Consumer,
              IOHIDElementGetUsage(element) == kHIDUsage_Csmr_ACHome else { return }
        let device = Unmanaged.passUnretained(IOHIDElementGetDevice(element)).toOpaque()
        edge(device, isDown: IOHIDValueGetIntegerValue(value) != 0)
    }

    private func edge(_ device: UnsafeMutableRawPointer, isDown: Bool) {
        let was = pressed[device] ?? false
        pressed[device] = isDown
        if isDown && !was {
            loungeLog.info("HID home pressed")
            onHome()
        }
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }
}
