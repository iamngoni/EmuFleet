import Foundation

enum AVDConstants {
    nonisolated static let customDeviceID = "__custom_profile__"
}

struct AndroidToolchain: Equatable {
    var sdkRoot: URL?
    var avdManagerURL: URL?
    var emulatorURL: URL?
    var adbURL: URL?
    var sdkManagerURL: URL?

    var isReady: Bool {
        sdkRoot != nil && avdManagerURL != nil && emulatorURL != nil && adbURL != nil
    }

    var missingComponents: [String] {
        var missing: [String] = []

        if sdkRoot == nil {
            missing.append("Android SDK root")
        }
        if avdManagerURL == nil {
            missing.append("avdmanager")
        }
        if emulatorURL == nil {
            missing.append("emulator")
        }
        if adbURL == nil {
            missing.append("adb")
        }

        return missing
    }

    var sdkRootDisplay: String {
        sdkRoot?.path ?? "Android SDK not found"
    }
}

struct SDKSetupState: Equatable {
    enum Phase: Equatable {
        case loading
        case requiresConfiguration
        case ready
    }

    var phase: Phase
    var proposedSDKRoot: URL?
    var message: String
    var detail: String?
    var scannedLocations: [String]

    static let loading = SDKSetupState(
        phase: .loading,
        proposedSDKRoot: nil,
        message: "Locating Android SDK…",
        detail: nil,
        scannedLocations: []
    )
}

struct InstalledSystemImage: Identifiable, Hashable {
    let packagePath: String
    let version: String
    let description: String
    let location: String

    var id: String { packagePath }

    var shortName: String {
        description.isEmpty ? packagePath : description
    }
}

struct DeviceDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let oem: String
    let tag: String?

    static let custom = DeviceDefinition(
        id: AVDConstants.customDeviceID,
        name: "Custom Profile",
        oem: "EmuFleet",
        tag: nil
    )

    var isCustom: Bool {
        id == AVDConstants.customDeviceID
    }

    var displayName: String {
        if isCustom {
            return name
        }
        if oem.isEmpty {
            return name
        }
        return "\(name) (\(oem))"
    }
}

struct AndroidVirtualDevice: Identifiable, Hashable {
    let name: String
    let displayName: String
    let bundlePath: URL
    let deviceName: String
    let manufacturer: String
    let systemImagePackage: String
    let target: String
    let tagID: String
    let tagDisplay: String
    let abi: String
    let skinName: String
    let sdCardSize: String
    let dataPartitionSize: String
    let ramSizeMB: String
    let vmHeapSizeMB: String
    let gpuMode: String
    let networkLatency: String
    let showDeviceFrame: Bool
    let quickBootEnabled: Bool
    let config: [String: String]
    let runningSerial: String?
    let isSystemImageAvailable: Bool

    var id: String { name }

    var isRunning: Bool {
        runningSerial != nil
    }

    var statusLabel: String {
        if !isSystemImageAvailable {
            return "Needs Repair"
        }
        return isRunning ? "Running" : "Stopped"
    }

    var statusSymbol: String {
        if !isSystemImageAvailable {
            return "exclamationmark.triangle.fill"
        }
        return isRunning ? "play.circle.fill" : "stop.circle.fill"
    }

    var subtitle: String {
        let parts = [
            target.replacingOccurrences(of: "android-", with: "Android "),
            tagDisplay,
            abi
        ].filter { !$0.isEmpty }
        return parts.joined(separator: " • ")
    }

    var immutableSummary: String {
        let parts = [
            deviceName,
            systemImagePackage,
            abi
        ].filter { !$0.isEmpty }
        return parts.joined(separator: " • ")
    }
}

enum AVDFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case stopped
    case repair

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .running: "Running"
        case .stopped: "Stopped"
        case .repair: "Repair"
        }
    }
}

enum AVDEditorMode: Equatable {
    case create
    case edit(originalName: String)
    case duplicate(sourceName: String)

    var saveTitle: String {
        switch self {
        case .create, .duplicate:
            return "Create"
        case .edit:
            return "Save"
        }
    }

    var detailTitle: String {
        switch self {
        case .create:
            return "Create AVD"
        case .edit:
            return "Edit AVD"
        case .duplicate:
            return "Duplicate AVD"
        }
    }

    var supportsDelete: Bool {
        if case .edit = self {
            return true
        }
        return false
    }

    var allowsImmutableChanges: Bool {
        switch self {
        case .create, .duplicate:
            return true
        case .edit:
            return false
        }
    }
}

struct AVDEditorDraft: Equatable {
    nonisolated private static let allowedNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))

    var mode: AVDEditorMode
    var name: String
    var displayName: String
    var deviceID: String
    var systemImagePackage: String
    var customDeviceName: String
    var customManufacturer: String
    var customScreenWidth: String
    var customScreenHeight: String
    var customScreenDensity: String
    var sdCardSize: String
    var dataPartitionSize: String
    var ramSizeMB: String
    var vmHeapSizeMB: String
    var gpuMode: String
    var networkLatency: String
    var showDeviceFrame: Bool
    var quickBootEnabled: Bool
    var originalDeviceID: String?
    var originalSystemImagePackage: String?

    var canDelete: Bool {
        mode.supportsDelete
    }

    var immutableFieldsLocked: Bool {
        !mode.allowsImmutableChanges
    }

    nonisolated var usesCustomDeviceProfile: Bool {
        deviceID == AVDConstants.customDeviceID
    }

    nonisolated var normalizedNameSuggestion: String {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? displayName : name
        return Self.normalizedName(from: source)
    }

    nonisolated var nameHelperText: String {
        if normalizedNameSuggestion.isEmpty {
            return "Internal identifier. Use letters, numbers, '.', '_' or '-'."
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName == normalizedNameSuggestion {
            return "Internal identifier used by the emulator. The display name can include spaces."
        }

        return "Will save as \(normalizedNameSuggestion). Only letters, numbers, '.', '_' and '-' are allowed."
    }

    nonisolated var customProfileHelperText: String {
        "Creates the AVD without a predefined template and writes this hardware profile directly into config.ini."
    }

    nonisolated var resolvedCustomDeviceName: String {
        let trimmed = customDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty {
            return display
        }

        return normalizedNameSuggestion.isEmpty ? "Custom Device" : Self.humanizedName(from: normalizedNameSuggestion)
    }

    nonisolated var resolvedCustomManufacturer: String {
        let trimmed = customManufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "EmuFleet" : trimmed
    }

    var title: String {
        switch mode {
        case .create:
            return "New Android Virtual Device"
        case .edit:
            return displayName.isEmpty ? "Edit Android Virtual Device" : displayName
        case .duplicate(let sourceName):
            return "Duplicate \(sourceName)"
        }
    }

    static func createDefault(deviceID: String? = nil, systemImagePackage: String? = nil) -> AVDEditorDraft {
        AVDEditorDraft(
            mode: .create,
            name: "",
            displayName: "",
            deviceID: deviceID ?? "",
            systemImagePackage: systemImagePackage ?? "",
            customDeviceName: "Custom Phone",
            customManufacturer: "EmuFleet",
            customScreenWidth: "1080",
            customScreenHeight: "2400",
            customScreenDensity: "420",
            sdCardSize: "512M",
            dataPartitionSize: "6G",
            ramSizeMB: "2048",
            vmHeapSizeMB: "256",
            gpuMode: "auto",
            networkLatency: "none",
            showDeviceFrame: true,
            quickBootEnabled: true,
            originalDeviceID: nil,
            originalSystemImagePackage: nil
        )
    }

    static func from(avd: AndroidVirtualDevice, mode: AVDEditorMode) -> AVDEditorDraft {
        AVDEditorDraft(
            mode: mode,
            name: avd.name,
            displayName: avd.displayName,
            deviceID: avd.deviceName,
            systemImagePackage: avd.systemImagePackage,
            customDeviceName: avd.config["hw.device.name"] ?? avd.displayName,
            customManufacturer: avd.config["hw.device.manufacturer"] ?? avd.manufacturer,
            customScreenWidth: avd.config["hw.lcd.width"] ?? "1080",
            customScreenHeight: avd.config["hw.lcd.height"] ?? "2400",
            customScreenDensity: avd.config["hw.lcd.density"] ?? "420",
            sdCardSize: avd.sdCardSize,
            dataPartitionSize: avd.dataPartitionSize,
            ramSizeMB: avd.ramSizeMB,
            vmHeapSizeMB: avd.vmHeapSizeMB,
            gpuMode: avd.gpuMode,
            networkLatency: avd.networkLatency,
            showDeviceFrame: avd.showDeviceFrame,
            quickBootEnabled: avd.quickBootEnabled,
            originalDeviceID: avd.deviceName,
            originalSystemImagePackage: avd.systemImagePackage
        )
    }

    nonisolated static func normalizedName(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        var scalars: [UnicodeScalar] = []
        var previousWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            if allowedNameCharacters.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = scalar == "_" || scalar == "-"
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !scalars.isEmpty && !previousWasSeparator {
                    scalars.append("_")
                    previousWasSeparator = true
                }
            }
        }

        let normalized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))

        return normalized
    }

    nonisolated private static func humanizedName(from value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AndroidWorkspaceSnapshot {
    let toolchain: AndroidToolchain
    let avds: [AndroidVirtualDevice]
    let devices: [DeviceDefinition]
    let systemImages: [InstalledSystemImage]
}

enum AndroidAVDError: LocalizedError {
    case toolNotFound(String)
    case invalidDraft(String)
    case immutableFieldChange
    case missingBundlePath
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) could not be located."
        case .invalidDraft(let message):
            return message
        case .immutableFieldChange:
            return "Changing the device profile or system image on an existing AVD is not a safe in-place edit. Duplicate it and create a new AVD instead."
        case .missingBundlePath:
            return "The selected AVD bundle could not be found on disk."
        case .commandFailed(let message):
            return message
        }
    }
}
