import AppKit
import Combine
import Foundation

@MainActor
final class AVDStore: ObservableObject {
    @Published var toolchain = AndroidToolchain()
    @Published var sdkSetup = SDKSetupState.loading
    @Published var avds: [AndroidVirtualDevice] = []
    @Published var deviceDefinitions: [DeviceDefinition] = []
    @Published var installedSystemImages: [InstalledSystemImage] = []
    @Published var searchText = ""
    @Published var filter: AVDFilter = .all
    @Published var selectedAVDName: String?
    @Published var draft: AVDEditorDraft?
    @Published var isBusy = false
    @Published var isConfiguringSDK = false
    @Published var errorMessage: String?
    @Published var lastRefreshDate: Date?

    private let service: AndroidAVDService
    private let userDefaults: UserDefaults

    private var hasBootstrapped = false
    private var configuredSDKRoot: URL?
    private var securityScopedSDKRoot: URL?

    private enum PersistenceKey {
        static let sdkPath = "sdkRootPath"
        static let sdkBookmark = "sdkRootBookmark"
    }

    init(service: AndroidAVDService = AndroidAVDService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
    }

    var filteredAVDs: [AndroidVirtualDevice] {
        avds.filter { avd in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .running:
                matchesFilter = avd.isRunning
            case .stopped:
                matchesFilter = !avd.isRunning && avd.isSystemImageAvailable
            case .repair:
                matchesFilter = !avd.isSystemImageAvailable
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery: Bool
            if query.isEmpty {
                matchesQuery = true
            } else {
                matchesQuery = [
                    avd.name,
                    avd.displayName,
                    avd.deviceName,
                    avd.subtitle
                ]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
            }

            return matchesFilter && matchesQuery
        }
    }

    var selectedAVD: AndroidVirtualDevice? {
        guard let selectedAVDName else {
            return nil
        }
        return avds.first(where: { $0.name == selectedAVDName })
    }

    var hasRunningAVD: Bool {
        avds.contains(where: \.isRunning)
    }

    var needsSDKSetup: Bool {
        sdkSetup.phase != .ready
    }

    func bootstrap() async {
        guard !hasBootstrapped else {
            return
        }

        hasBootstrapped = true
        await evaluateSDKSetup()
    }

    func refreshSDKDetection() async {
        await evaluateSDKSetup(forceDetectionRefresh: true)
    }

    func confirmProposedSDKRoot() async {
        guard let proposedSDKRoot = sdkSetup.proposedSDKRoot else {
            chooseCustomSDKRoot()
            return
        }

        await configureSDKRoot(proposedSDKRoot)
    }

    func chooseCustomSDKRoot() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose SDK"
        panel.message = "Select the root folder of your Android SDK."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = sdkSetup.proposedSDKRoot ?? configuredSDKRoot

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        Task {
            await configureSDKRoot(selectedURL)
        }
    }

    func refresh() async {
        guard let configuredSDKRoot else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        let resolvedToolchain = await service.resolveToolchain(preferredSDKRoot: configuredSDKRoot)
        toolchain = resolvedToolchain

        guard resolvedToolchain.isReady else {
            clearWorkspace()
            self.configuredSDKRoot = nil
            sdkSetup = SDKSetupState(
                phase: .requiresConfiguration,
                proposedSDKRoot: configuredSDKRoot,
                message: "The configured Android SDK path is no longer valid.",
                detail: sdkSetupDetail(for: resolvedToolchain),
                scannedLocations: []
            )
            clearPersistedSDKRoot()
            return
        }

        do {
            let snapshot = try await service.loadWorkspace(preferredSDKRoot: configuredSDKRoot)
            toolchain = snapshot.toolchain
            sdkSetup = SDKSetupState(
                phase: .ready,
                proposedSDKRoot: configuredSDKRoot,
                message: "Android SDK configured.",
                detail: nil,
                scannedLocations: []
            )
            avds = snapshot.avds
            deviceDefinitions = snapshot.devices
            installedSystemImages = snapshot.systemImages
            lastRefreshDate = Date()

            if let selectedAVDName, !avds.contains(where: { $0.name == selectedAVDName }) {
                self.selectedAVDName = nil
            }

            if case .create = draft?.mode {
                applyDefaultValuesToDraftIfNeeded()
            }

            if let selectedAVD {
                draft = normalizeDeviceProfile(in: .from(avd: selectedAVD, mode: .edit(originalName: selectedAVD.name)))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginCreateDraft() {
        selectedAVDName = nil
        draft = AVDEditorDraft.createDefault(
            deviceID: deviceDefinitions.first?.id,
            systemImagePackage: installedSystemImages.first?.packagePath
        )
    }

    func beginDuplicateDraft(from avd: AndroidVirtualDevice) {
        selectedAVDName = nil
        var nextDraft = AVDEditorDraft.from(avd: avd, mode: .duplicate(sourceName: avd.name))
        nextDraft.name = "\(avd.name)_copy"
        nextDraft.displayName = "\(avd.displayName) Copy"
        draft = normalizeDeviceProfile(in: nextDraft)
    }

    func selectAVD(named name: String?) {
        selectedAVDName = name
        guard let name, let avd = avds.first(where: { $0.name == name }) else {
            if case .create = draft?.mode {
                return
            } else {
                draft = nil
            }
            return
        }
        draft = normalizeDeviceProfile(in: .from(avd: avd, mode: .edit(originalName: avd.name)))
    }

    func saveCurrentDraft() async {
        guard var draftToSave = draft else {
            return
        }

        let preferredNameSource = draftToSave.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draftToSave.displayName
            : draftToSave.name
        let normalizedName = AVDEditorDraft.normalizedName(from: preferredNameSource)

        guard !normalizedName.isEmpty else {
            errorMessage = "Enter an AVD Name using letters, numbers, '.', '_' or '-'."
            return
        }

        draftToSave.name = normalizedName
        draft = draftToSave

        isBusy = true
        defer { isBusy = false }

        do {
            try await service.saveDraft(draftToSave, toolchain: toolchain)
            await refresh()
            selectedAVDName = draftToSave.name
            if let saved = avds.first(where: { $0.name == draftToSave.name }) {
                self.draft = .from(avd: saved, mode: .edit(originalName: saved.name))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launch(_ avd: AndroidVirtualDevice, coldBoot: Bool = false, wipeData: Bool = false) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await service.launchAVD(named: avd.name, coldBoot: coldBoot, wipeData: wipeData, toolchain: toolchain)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ avd: AndroidVirtualDevice) async {
        guard let serial = avd.runningSerial else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await service.stopAVD(serial: serial, toolchain: toolchain)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ avd: AndroidVirtualDevice) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await service.deleteAVD(avd, toolchain: toolchain)
            if selectedAVDName == avd.name {
                selectedAVDName = nil
                draft = nil
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func wipeData(_ avd: AndroidVirtualDevice) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await service.wipeData(for: avd)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ avd: AndroidVirtualDevice) {
        NSWorkspace.shared.activateFileViewerSelecting([avd.bundlePath])
    }

    func clearError() {
        errorMessage = nil
    }

    private func evaluateSDKSetup(forceDetectionRefresh: Bool = false) async {
        isConfiguringSDK = true
        defer { isConfiguringSDK = false }

        clearError()

        let restoredSDKRoot = forceDetectionRefresh ? nil : restorePersistedSDKRoot()
        if let restoredSDKRoot {
            let persistedToolchain = await service.resolveToolchain(preferredSDKRoot: restoredSDKRoot)
            toolchain = persistedToolchain

            if persistedToolchain.isReady {
                configuredSDKRoot = restoredSDKRoot
                sdkSetup = SDKSetupState(
                    phase: .ready,
                    proposedSDKRoot: restoredSDKRoot,
                    message: "Android SDK configured.",
                    detail: nil,
                    scannedLocations: []
                )
                await refresh()
                return
            }
        }

        clearWorkspace()
        configuredSDKRoot = nil

        let scannedLocations = await service.sdkRootSearchLocations().map(\.path)
        let detectedSDKRoot = await service.discoverSDKRootCandidate()
        let previewToolchain = await service.resolveToolchain(preferredSDKRoot: detectedSDKRoot)
        toolchain = previewToolchain

        let message: String
        if restoredSDKRoot != nil {
            message = "The saved SDK path is no longer valid. Confirm the detected path or choose another folder."
            clearPersistedSDKRoot()
        } else if detectedSDKRoot != nil {
            message = "Confirm the Android SDK path before EmuFleet starts managing AVDs."
        } else {
            message = "EmuFleet couldn't find an Android SDK automatically. Choose your SDK folder to continue."
        }

        sdkSetup = SDKSetupState(
            phase: .requiresConfiguration,
            proposedSDKRoot: detectedSDKRoot,
            message: message,
            detail: sdkSetupDetail(for: previewToolchain),
            scannedLocations: scannedLocations
        )
    }

    private func configureSDKRoot(_ url: URL) async {
        let normalizedURL = url.standardizedFileURL

        isConfiguringSDK = true
        defer { isConfiguringSDK = false }

        clearError()

        let resolvedToolchain = await service.resolveToolchain(preferredSDKRoot: normalizedURL)
        toolchain = resolvedToolchain

        guard resolvedToolchain.isReady else {
            clearWorkspace()
            configuredSDKRoot = nil
            sdkSetup = SDKSetupState(
                phase: .requiresConfiguration,
                proposedSDKRoot: normalizedURL,
                message: "That folder doesn't look like a complete Android SDK.",
                detail: sdkSetupDetail(for: resolvedToolchain),
                scannedLocations: []
            )
            return
        }

        persistSDKRoot(normalizedURL)
        configuredSDKRoot = normalizedURL
        sdkSetup = SDKSetupState(
            phase: .ready,
            proposedSDKRoot: normalizedURL,
            message: "Android SDK configured.",
            detail: nil,
            scannedLocations: []
        )
        await refresh()
    }

    private func sdkSetupDetail(for toolchain: AndroidToolchain) -> String? {
        guard !toolchain.missingComponents.isEmpty else {
            return nil
        }

        return "Missing: \(toolchain.missingComponents.joined(separator: ", "))"
    }

    private func clearWorkspace() {
        avds = []
        deviceDefinitions = []
        installedSystemImages = []
        selectedAVDName = nil
        draft = nil
        lastRefreshDate = nil
    }

    private func persistSDKRoot(_ url: URL) {
        userDefaults.set(url.path, forKey: PersistenceKey.sdkPath)

        if let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            userDefaults.set(bookmarkData, forKey: PersistenceKey.sdkBookmark)
            beginAccessingSecurityScopedRoot(url)
        } else {
            userDefaults.removeObject(forKey: PersistenceKey.sdkBookmark)
        }
    }

    private func restorePersistedSDKRoot() -> URL? {
        if let bookmarkData = userDefaults.data(forKey: PersistenceKey.sdkBookmark) {
            var isStale = false
            if let restoredURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                beginAccessingSecurityScopedRoot(restoredURL)

                if isStale,
                   let refreshedBookmarkData = try? restoredURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                   ) {
                    userDefaults.set(refreshedBookmarkData, forKey: PersistenceKey.sdkBookmark)
                }

                userDefaults.set(restoredURL.path, forKey: PersistenceKey.sdkPath)
                return restoredURL.standardizedFileURL
            }
        }

        guard let storedPath = userDefaults.string(forKey: PersistenceKey.sdkPath), !storedPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: storedPath).standardizedFileURL
    }

    private func clearPersistedSDKRoot() {
        userDefaults.removeObject(forKey: PersistenceKey.sdkPath)
        userDefaults.removeObject(forKey: PersistenceKey.sdkBookmark)
        securityScopedSDKRoot?.stopAccessingSecurityScopedResource()
        securityScopedSDKRoot = nil
    }

    private func beginAccessingSecurityScopedRoot(_ url: URL) {
        let normalizedURL = url.standardizedFileURL

        if securityScopedSDKRoot == normalizedURL {
            return
        }

        securityScopedSDKRoot?.stopAccessingSecurityScopedResource()
        securityScopedSDKRoot = nil

        if normalizedURL.startAccessingSecurityScopedResource() {
            securityScopedSDKRoot = normalizedURL
        }
    }

    private func applyDefaultValuesToDraftIfNeeded() {
        guard var draft else {
            return
        }
        if draft.deviceID.isEmpty {
            draft.deviceID = deviceDefinitions.first?.id ?? ""
        }
        if draft.systemImagePackage.isEmpty {
            draft.systemImagePackage = installedSystemImages.first?.packagePath ?? ""
        }
        self.draft = draft
    }

    private func normalizeDeviceProfile(in draft: AVDEditorDraft) -> AVDEditorDraft {
        guard !draft.deviceID.isEmpty else {
            return draft
        }

        if draft.deviceID == AVDConstants.customDeviceID || deviceDefinitions.contains(where: { $0.id == draft.deviceID }) {
            return draft
        }

        var normalizedDraft = draft
        normalizedDraft.deviceID = AVDConstants.customDeviceID
        return normalizedDraft
    }
}
