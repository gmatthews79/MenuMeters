//
//  DiskIO.swift
//  MenuMeters
//
//  Block-device read/write activity from IOKit.
//
//  Copyright (c) 2002-2014 Alex Harper
//  Copyright (c) 2015-2026 The MenuMeters contributors (see the Git history)
//
//  This file is part of MenuMeters.
//
//  MenuMeters is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License version 2 as
//  published by the Free Software Foundation.
//
//  MenuMeters is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with MenuMeters; if not, see <https://www.gnu.org/licenses/>.
//
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Changes:
//  2026-10     gonejack: rewritten in Swift from the Objective-C original.
//  2026-10-30  Luca Gibelli: restored the license notice.
//  2026-11-18  Luca Gibelli: byte counts of the startup disk alone.
//

import Cocoa
import IOKit

final class DiskIO {
    private static let driverClass = "IOBlockStorageDriver"
    private static let statisticsKey = "Statistics"
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWrittenKey = "Bytes (Write)"

    private var masterPort: mach_port_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifyRunSource: CFRunLoopSource?
    private var publishedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var deviceIterator: io_iterator_t = 0
    private var previousTotalRead: UInt64 = 0
    private var previousTotalWrite: UInt64 = 0
    /// The drivers of the physical disks the startup volume is on: one, or
    /// more for a Fusion Drive or a RAID set.
    private var startupDrivers: [io_registry_entry_t] = []
    private var startupDriversResolved = false

    init?() {
        guard IOMainPort(mach_port_t(MACH_PORT_NULL), &masterPort) == KERN_SUCCESS, masterPort != 0 else {
            return nil
        }
        guard let port = IONotificationPortCreate(masterPort) else { return nil }
        notifyPort = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            cleanup()
            return nil
        }
        notifyRunSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<DiskIO>.fromOpaque(refcon).takeUnretainedValue().blockDeviceChanged(iterator)
        }
        guard IOServiceAddMatchingNotification(port, kIOPublishNotification,
                                               IOServiceMatching(Self.driverClass),
                                               callback, refcon, &publishedIterator) == KERN_SUCCESS,
              IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                               IOServiceMatching(Self.driverClass),
                                               callback, refcon, &terminatedIterator) == KERN_SUCCESS else {
            cleanup()
            return nil
        }

        // Drain the notification iterators and seed the counters.
        blockDeviceChanged(publishedIterator)
        blockDeviceChanged(terminatedIterator)
        _ = diskIOActivity()
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        releaseStartupDrivers()
        if deviceIterator != 0 { IOObjectRelease(deviceIterator); deviceIterator = 0 }
        if publishedIterator != 0 { IOObjectRelease(publishedIterator); publishedIterator = 0 }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator); terminatedIterator = 0 }
        if let notifyRunSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), notifyRunSource, .defaultMode)
            self.notifyRunSource = nil
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        if masterPort != 0 {
            mach_port_deallocate(mach_task_self_, masterPort)
            masterPort = 0
        }
    }

    // MARK: - Activity

    func diskIOActivity() -> DiskActivity {
        if deviceIterator == 0 {
            guard IOServiceGetMatchingServices(masterPort, IOServiceMatching(Self.driverClass),
                                               &deviceIterator) == KERN_SUCCESS else {
                return .idle
            }
        }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        while true {
            let entry = IOIteratorNext(deviceIterator)
            guard entry != 0 else { break }
            if let bytes = Self.byteCounts(of: entry) {
                totalRead += bytes.read
                totalWrite += bytes.written
            }
            IOObjectRelease(entry)
        }
        IOIteratorReset(deviceIterator)

        // Only changes matter: unmounts and counter overflows are treated as
        // activity too, which is close enough for a menu bar indicator.
        let activity: DiskActivity
        if totalRead != previousTotalRead && totalWrite != previousTotalWrite {
            activity = .readWrite
        } else if totalRead != previousTotalRead {
            activity = .read
        } else if totalWrite != previousTotalWrite {
            activity = .write
        } else {
            activity = .idle
        }
        previousTotalRead = totalRead
        previousTotalWrite = totalWrite
        return activity
    }

    // MARK: - Startup disk

    /// Bytes read from and written to the startup disk since it appeared, or
    /// nil if its counters cannot be found. Other disks are not counted. A
    /// disk image stored on the startup disk counts once, as reads and writes
    /// of its file, and not a second time as a disk of its own.
    func startupDiskByteCounts() -> (read: UInt64, written: UInt64)? {
        if !startupDriversResolved {
            startupDrivers = Self.findStartupDrivers(masterPort)
            startupDriversResolved = true
        }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        for driver in startupDrivers {
            guard let bytes = Self.byteCounts(of: driver) else { continue }
            read += bytes.read
            written += bytes.written
            found = true
        }
        return found ? (read, written) : nil
    }

    private func releaseStartupDrivers() {
        startupDrivers.forEach { IOObjectRelease($0) }
        startupDrivers = []
        startupDriversResolved = false
    }

    /// The block storage drivers below the startup volume. From the volume's
    /// media (an APFS snapshot or volume) the service plane leads up through
    /// the APFS container and the partition to the physical disk, whose driver
    /// keeps the statistics. Every parent is followed, so a container spread
    /// over several disks yields all of them.
    private static func findStartupDrivers(_ port: mach_port_t) -> [io_registry_entry_t] {
        var mount = statfs()
        guard statfs("/", &mount) == 0 else { return [] }
        let device = withUnsafeBytes(of: mount.f_mntfromname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard device.hasPrefix("/dev/") else { return [] }
        let media = IOServiceGetMatchingService(port, IOBSDNameMatching(port, 0, String(device.dropFirst(5))))
        guard media != 0 else { return [] }

        var drivers: [io_registry_entry_t] = []
        var level = [media]
        // The chain is about ten entries long; the limit only guards against
        // a registry that is not the tree it should be.
        for _ in 0..<32 where !level.isEmpty {
            var parents: [io_registry_entry_t] = []
            for entry in level {
                if IOObjectConformsTo(entry, driverClass) != 0 {
                    drivers.append(entry)
                    continue
                }
                var iterator: io_iterator_t = 0
                if IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS {
                    while case let parent = IOIteratorNext(iterator), parent != 0 {
                        parents.append(parent)
                    }
                    IOObjectRelease(iterator)
                }
                IOObjectRelease(entry)
            }
            level = parents
        }
        level.forEach { IOObjectRelease($0) }
        return drivers
    }

    private static func byteCounts(of driver: io_registry_entry_t) -> (read: UInt64, written: UInt64)? {
        guard let statistics = IORegistryEntryCreateCFProperty(driver, statisticsKey as CFString,
                                                               kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        return ((statistics[bytesReadKey] as? NSNumber)?.uint64Value ?? 0,
                (statistics[bytesWrittenKey] as? NSNumber)?.uint64Value ?? 0)
    }

    private func blockDeviceChanged(_ iterator: io_iterator_t) {
        // A disk came or went: look the startup disk up again on next use.
        releaseStartupDrivers()
        if deviceIterator != 0 {
            IOObjectRelease(deviceIterator)
            deviceIterator = 0
        }
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            IOObjectRelease(device)
        }
    }
}
