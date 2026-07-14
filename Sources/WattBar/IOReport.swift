import Foundation
import WattBarCore

// libIOReport is a private but stable system library (linked via its SDK
// stub). It exposes the SoC "Energy Model" counters — per-component energy
// for CPU, GPU, and ANE — readable without root.
@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(
    _ group: CFString?, _ subgroup: CFString?,
    _ a: UInt64, _ b: UInt64, _ c: UInt64
) -> Unmanaged<CFMutableDictionary>?

@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(
    _ allocator: UnsafeRawPointer?,
    _ desiredChannels: CFMutableDictionary,
    _ subscribedChannels: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
    _ channelID: UInt64, _ options: CFTypeRef?
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(
    _ subscription: CFTypeRef, _ channels: CFMutableDictionary, _ options: CFTypeRef?
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(
    _ previous: CFDictionary, _ current: CFDictionary, _ options: CFTypeRef?
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ channel: CFDictionary, _ index: Int32) -> Int64

/// Samples the SoC energy counters and converts deltas to average watts.
final class EnergyModel {
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var previousSample: CFDictionary?
    private var previousSampleTime: ContinuousClock.Instant?

    init?() {
        guard let channels = IOReportCopyChannelsInGroup(
            "Energy Model" as CFString, nil, 0, 0, 0
        )?.takeRetainedValue() else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(
            nil, channels, &subscribed, 0, nil
        )?.takeRetainedValue() else { return nil }
        subscribed?.release()

        self.subscription = subscription
        self.channels = channels
    }

    /// Returns average power per component since the previous call, or nil on
    /// the first call (no interval to average over yet).
    func sample() -> [ComponentSample]? {
        guard let current = IOReportCreateSamples(subscription, channels, nil)?
            .takeRetainedValue()
        else { return nil }
        let now = ContinuousClock.now

        defer {
            previousSample = current
            previousSampleTime = now
        }

        guard let previous = previousSample,
              let previousTime = previousSampleTime,
              let delta = IOReportCreateSamplesDelta(previous, current, nil)?
                  .takeRetainedValue()
        else { return nil }

        let seconds = previousTime.duration(to: now).timeInterval
        guard seconds > 0 else { return nil }

        let key = "IOReportChannels" as CFString
        guard let raw = CFDictionaryGetValue(
            delta, Unmanaged.passUnretained(key).toOpaque()
        ) else { return nil }
        let channelList = Unmanaged<CFArray>.fromOpaque(raw)
            .takeUnretainedValue() as [AnyObject]

        return channelList.compactMap { entry -> ComponentSample? in
            // CF casts are unchecked bridges, so `as?` would not reliably fail
            // for a non-dictionary CF value; check the type ID instead.
            guard CFGetTypeID(entry) == CFDictionaryGetTypeID() else { return nil }
            let channel = entry as! CFDictionary
            guard let name = IOReportChannelGetChannelName(channel)?
                .takeUnretainedValue() as String?
            else { return nil }
            let unit = IOReportChannelGetUnitLabel(channel)
                .map { ($0.takeUnretainedValue() as String) } ?? ""
            let value = IOReportSimpleGetIntegerValue(channel, 0)
            guard let joules = IOReportUnits.joules(value: value, unit: unit) else { return nil }
            return ComponentSample(name: name, watts: joules / seconds)
        }
    }
}
