// OutputDeviceRouter.swift
// Analyses the OutputChannelMatrixConfig and determines the correct routing mode.
// Creates and manages the appropriate routing infrastructure.

import CoreAudio
import Foundation
import OSLog

enum MultiDeviceSyncMode: Int, Codable, Equatable, Sendable, CaseIterable {
    /// Default. CoreAudio aggregate device handles synchronisation.
    /// Adds ~12–24 ms SRC latency on slave devices. Most compatible.
    case aggregateDevice = 0
    /// Software PLL. No aggregate device. No SRC latency.
    /// Higher CPU, requires careful PLL tuning. Best phase accuracy.
    case softwarePLL = 1

    var displayName: String {
        switch self {
        case .aggregateDevice: return "Aggregate Device (recommended)"
        case .softwarePLL:     return "Software PLL"
        }
    }

    var shortName: String {
        switch self {
        case .aggregateDevice: return "Aggregate"
        case .softwarePLL:     return "Software PLL"
        }
    }
}

/// Determines routing mode and creates appropriate infrastructure.
@MainActor
final class OutputDeviceRouter {

    enum RoutingMode: CustomStringConvertible {
        case singleDevice(deviceID: AudioDeviceID, channelMap: [ChannelMapSlot])
        case aggregateDevice(aggregateID: AudioDeviceID, channelMap: [ChannelMapSlot])
        case softwarePLL(primaryDeviceID: AudioDeviceID,
                         primaryChannelMap: [ChannelMapSlot],
                         secondaryWriters: [PLLSRCWriter])

        var description: String {
            switch self {
            case .singleDevice(let deviceID, _):
                return "singleDevice(\(deviceID))"
            case .aggregateDevice(let aggID, _):
                return "aggregateDevice(\(aggID))"
            case .softwarePLL(let primaryID, _, let writers):
                return "softwarePLL(primary: \(primaryID), writers: \(writers.count))"
            }
        }
    }

    /// Analyses the matrix config and resolves a routing mode.
    /// Called on the main thread before pipeline start.
    /// - Parameters:
    ///   - matrix: The validated output channel matrix config.
    ///   - syncMode: User's preferred multi-device sync mode.
    ///   - deviceProvider: For resolving UIDs → AudioDeviceIDs.
    ///   - explicitPrimaryDeviceUID: User-chosen primary/clock-master device, if any
    ///     (aggregateClockMasterUID for Aggregate mode, pllPrimaryDeviceUID for
    ///     Software PLL — caller picks whichever matches `syncMode`). nil, or a UID
    ///     that no longer matches any enabled channel's target, falls back to
    ///     matrix.channels[0]'s device.
    /// - Returns: The resolved routing mode, or throws on unresolvable config.
    static func resolve(
        matrix: OutputChannelMatrixConfig,
        syncMode: MultiDeviceSyncMode,
        deviceProvider: any DeviceProviding,
        aggregateManager: AggregateDeviceManager,
        currentSampleRate: Double,
        explicitPrimaryDeviceUID: String? = nil
    ) async throws -> RoutingMode {

        // Collect all unique device UIDs referenced by enabled channels, keeping each
        // channel's GLOBAL index (position in the full matrix) alongside it — needed
        // so buildChannelMap's output values match RenderCallbackContext's chIdx
        // convention rather than a per-device-local renumbering.
        let indexedChannels = matrix.channels.enumerated().map { (globalIndex: $0, channel: $1) }
        let enabledIndexedChannels = indexedChannels.filter { $0.channel.isEnabled }
        let uniqueUIDs = Set(enabledIndexedChannels.compactMap { $0.channel.target?.deviceUID })

        // Single device: all channels target the same UID
        if uniqueUIDs.count <= 1 {
            guard let uid = uniqueUIDs.first,
                  let deviceID = deviceProvider.deviceID(forUID: uid) else {
                throw OutputRoutingError.primaryDeviceNotFound
            }
            let map = buildChannelMap(channels: enabledIndexedChannels,
                                      deviceID: deviceID,
                                      deviceProvider: deviceProvider)
            return .singleDevice(deviceID: deviceID, channelMap: map)
        }

        // Resolve the primary/clock-master device. Honors an explicit user choice
        // (aggregateClockMasterUID or pllPrimaryDeviceUID — whichever matches
        // syncMode, decided by the caller) when it's set and still valid, i.e. still
        // targeted by one of the enabled channels. Otherwise falls back to
        // matrix.channels[0]'s device — anchored explicitly rather than inferred from
        // array-filtering order, which could silently diverge during a transient
        // per-channel solo (see EqualiserStore.soloOutputChannel). Fails loudly if
        // channel 0 is disabled at this point rather than silently falling back to
        // some other channel — that should never happen in practice (solo
        // measurements deliberately don't trigger routing reconfiguration), so if this
        // guard ever fires, something upstream is behaving unexpectedly and deserves
        // investigation rather than a silent fallback.
        let primaryUID: String
        if let explicitPrimaryDeviceUID, uniqueUIDs.contains(explicitPrimaryDeviceUID) {
            primaryUID = explicitPrimaryDeviceUID
        } else {
            guard let primaryChannel = matrix.channels.first, primaryChannel.isEnabled,
                  let fallbackUID = primaryChannel.target?.deviceUID else {
                throw OutputRoutingError.primaryChannelDisabled
            }
            primaryUID = fallbackUID
        }

        // Multiple devices: check sync mode preference
        switch syncMode {
        case .aggregateDevice:
            let aggID = try await aggregateManager.createOrUpdate(
                channels: enabledIndexedChannels.map { $0.channel },
                deviceProvider: deviceProvider,
                clockMasterUID: primaryUID
            )
            let map = buildChannelMap(channels: enabledIndexedChannels,
                                      deviceID: aggID,
                                      deviceProvider: deviceProvider)
            return .aggregateDevice(aggregateID: aggID, channelMap: map)

        case .softwarePLL:
            guard let primaryID = deviceProvider.deviceID(forUID: primaryUID) else {
                throw OutputRoutingError.primaryDeviceNotFound
            }
            let primaryMap = buildChannelMap(
                channels: enabledIndexedChannels.filter { $0.channel.target?.deviceUID == primaryUID },
                deviceID: primaryID,
                deviceProvider: deviceProvider
            )
            let secondaryUIDs = uniqueUIDs.subtracting([primaryUID])
            let writers: [PLLSRCWriter] = try secondaryUIDs.sorted().map { uid in
                guard let deviceID = deviceProvider.deviceID(forUID: uid) else {
                    throw OutputRoutingError.secondaryDeviceNotFound(uid: uid)
                }
                let channels = enabledIndexedChannels.filter { $0.channel.target?.deviceUID == uid }
                let map = buildChannelMap(channels: channels, deviceID: deviceID,
                                         deviceProvider: deviceProvider)
                let config = PLLSRCWriter.Config(
                    deviceID: deviceID,
                    deviceUID: uid,
                    channelMap: map,
                    nominalSampleRate: currentSampleRate
                )
                return PLLSRCWriter(config: config)
            }
            return .softwarePLL(primaryDeviceID: primaryID,
                                primaryChannelMap: primaryMap,
                                secondaryWriters: writers)
        }
    }

    /// Builds a CoreAudio channel map for writing to specific device channels.
    /// Result array length = total output channel count on the device.
    /// Entry at index i = processing channel that writes to device channel i, or .silence.
    private static func buildChannelMap(
        channels: [(globalIndex: Int, channel: OutputChannelConfig)],
        deviceID: AudioDeviceID,
        deviceProvider: any DeviceProviding
    ) -> [ChannelMapSlot] {
        let totalDeviceChannels = deviceProvider.outputChannelCount(deviceID: deviceID)
        var map = [ChannelMapSlot](repeating: .silence, count: totalDeviceChannels)
        for (globalIndex, channel) in channels {
            guard let indices = channel.target?.channelIndices else { continue }
            // Position determines side: channelIndices[0] is left/mono, [1] is right.
            // (OutputTarget.channelIndices is documented as "1 or 2 channel indices" —
            // anything beyond position 1 is ignored rather than guessed at.)
            for (position, deviceChannelIndex) in indices.enumerated() {
                guard deviceChannelIndex < totalDeviceChannels, position < 2 else { continue }
                map[deviceChannelIndex] = position == 0
                    ? .left(Int32(globalIndex))
                    : .right(Int32(globalIndex))
            }
        }
        return map
    }
}

enum OutputRoutingError: LocalizedError {
    case primaryDeviceNotFound
    /// matrix.channels[0] is disabled. Shouldn't happen outside a transient per-channel
    /// solo (EqualiserStore.soloOutputChannel), which doesn't trigger routing
    /// resolution — if this fires, something upstream changed that assumption.
    case primaryChannelDisabled
    case secondaryDeviceNotFound(uid: String)
    case aggregateDeviceCreationFailed(OSStatus)
    case incompatibleSampleRates([String: Double])

    var errorDescription: String? {
        switch self {
        case .primaryDeviceNotFound:
            return "Primary output device not found"
        case .primaryChannelDisabled:
            return "Primary channel (channel 0) is disabled"
        case .secondaryDeviceNotFound(let uid):
            return "Secondary output device not found: \(uid)"
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate device: \(status)"
        case .incompatibleSampleRates(let rates):
            return "Incompatible sample rates: \(rates)"
        }
    }
}
