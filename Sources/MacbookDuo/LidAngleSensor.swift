import Foundation
import IOKit.hid

/// Reads the MacBook lid angle from the internal `las` HID sensor.
///
/// The device reports a single feature report (id 1) of three bytes:
/// `[reportID, angleLow, angleHigh]`, where the 16-bit value is degrees between
/// the keyboard deck and the display. A fully closed lid reads ~0, flat reads ~180.
final class LidAngleSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Opens the sensor. Returns false when the machine has no lid angle sensor
    /// (external keyboards, desktop Macs, older MacBooks).
    func open() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first
        else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        self.manager = manager
        self.device = device
        return readAngle() != nil
    }

    func close() {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
    }

    /// Current lid angle in degrees, or nil when the report cannot be read
    /// (which happens transiently around sleep/wake).
    func readAngle() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        let degrees = Double(raw)
        guard degrees >= 0, degrees <= 360 else { return nil }
        return degrees
    }
}
