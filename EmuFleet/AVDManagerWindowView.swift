import SwiftUI

struct AVDManagerWindowView: View {
    @EnvironmentObject private var store: AVDStore

    @State private var deleteCandidate: AndroidVirtualDevice?
    @State private var wipeCandidate: AndroidVirtualDevice?

    var body: some View {
        Group {
            if store.needsSDKSetup {
                SDKSetupView(compact: false)
            } else {
                NavigationSplitView {
                    List(selection: Binding(
                        get: { store.selectedAVDName },
                        set: { store.selectAVD(named: $0) }
                    )) {
                        Section("Devices") {
                            ForEach(store.filteredAVDs) { avd in
                                SidebarAVDRow(avd: avd)
                                    .tag(Optional(avd.name))
                                    .contextMenu {
                                        Button("Duplicate") {
                                            store.beginDuplicateDraft(from: avd)
                                        }
                                        Button("Reveal in Finder") {
                                            store.revealInFinder(avd)
                                        }
                                        Divider()
                                        Button("Wipe Data…", role: .destructive) {
                                            wipeCandidate = avd
                                        }
                                        Button("Delete…", role: .destructive) {
                                            deleteCandidate = avd
                                        }
                                    }
                            }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260)
                    .searchable(text: $store.searchText, placement: .sidebar)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                store.beginCreateDraft()
                            } label: {
                                Label("New", systemImage: "plus")
                            }

                            Button {
                                if let selected = store.selectedAVD {
                                    store.beginDuplicateDraft(from: selected)
                                }
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }
                            .disabled(store.selectedAVD == nil)

                            Button {
                                Task { await store.refresh() }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        sidebarFooter
                    }
                } detail: {
                    if let _ = store.draft {
                        AVDEditorFormView(
                            draft: Binding(
                                get: { store.draft ?? AVDEditorDraft.createDefault() },
                                set: { store.draft = $0 }
                            ),
                            availableDevices: store.deviceDefinitions,
                            installedImages: store.installedSystemImages,
                            selectedAVD: store.selectedAVD,
                            onSave: {
                                Task { await store.saveCurrentDraft() }
                            },
                            onLaunch: {
                                if let avd = store.selectedAVD {
                                    Task { await store.launch(avd) }
                                }
                            },
                            onStop: {
                                if let avd = store.selectedAVD {
                                    Task { await store.stop(avd) }
                                }
                            },
                            onDuplicate: {
                                if let selected = store.selectedAVD {
                                    store.beginDuplicateDraft(from: selected)
                                }
                            },
                            onReveal: {
                                if let avd = store.selectedAVD {
                                    store.revealInFinder(avd)
                                }
                            },
                            onWipe: {
                                wipeCandidate = store.selectedAVD
                            },
                            onDelete: {
                                deleteCandidate = store.selectedAVD
                            }
                        )
                    } else {
                        ContentUnavailableView(
                            "No AVD Selected",
                            systemImage: "rectangle.split.3x1",
                            description: Text("Choose a device from the sidebar or create a new Android Virtual Device.")
                        )
                    }
                }
            }
        }
        .task {
            await store.bootstrap()
        }
        .confirmationDialog(
            deleteCandidate.map { "Delete \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { avd in
            Button("Delete", role: .destructive) {
                Task { await store.delete(avd) }
            }
        } message: { _ in
            Text("The AVD bundle and userdata will be removed from disk.")
        }
        .confirmationDialog(
            wipeCandidate.map { "Wipe data for \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { wipeCandidate != nil },
                set: { if !$0 { wipeCandidate = nil } }
            ),
            presenting: wipeCandidate
        ) { avd in
            Button("Wipe Data", role: .destructive) {
                Task { await store.wipeData(avd) }
            }
        } message: { _ in
            Text("This removes the writable emulator disk images and resets the virtual device.")
        }
        .alert(
            "EmuFleet",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.toolchain.isReady ? "SDK Ready" : "SDK Missing")
                        .font(.caption.weight(.semibold))
                    Text(store.toolchain.sdkRootDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Change SDK…") {
                        store.chooseCustomSDKRoot()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct SidebarAVDRow: View {
    let avd: AndroidVirtualDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: avd.statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(avd.displayName)
                    .lineLimit(1)
                Text(avd.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        if !avd.isSystemImageAvailable {
            return .orange
        }
        return avd.isRunning ? .green : .secondary
    }
}

private struct AVDEditorFormView: View {
    @Binding var draft: AVDEditorDraft

    let availableDevices: [DeviceDefinition]
    let installedImages: [InstalledSystemImage]
    let selectedAVD: AndroidVirtualDevice?
    let onSave: () -> Void
    let onLaunch: () -> Void
    let onStop: () -> Void
    let onDuplicate: () -> Void
    let onReveal: () -> Void
    let onWipe: () -> Void
    let onDelete: () -> Void

    private let gpuModes = ["auto", "host", "swiftshader_indirect"]
    private let networkModes = ["none", "gprs", "edge", "umts", "lte", "full"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader

                if draft.immutableFieldsLocked {
                    Label("System image and device profile changes require duplicating into a new AVD.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("AVD Name") {
                            TextField("Pixel_9_Pro", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 280)
                        }

                        LabeledContent("Display Name") {
                            TextField("Pixel 9 Pro", text: $draft.displayName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 280)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Base Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Device Profile") {
                            Picker("Device Profile", selection: $draft.deviceID) {
                                ForEach(availableDevices) { device in
                                    Text(device.displayName).tag(device.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 320)
                            .disabled(draft.immutableFieldsLocked)
                        }

                        LabeledContent("System Image") {
                            Picker("System Image", selection: $draft.systemImagePackage) {
                                ForEach(installedImages) { image in
                                    Text(image.shortName).tag(image.packagePath)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 320)
                            .disabled(draft.immutableFieldsLocked)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Resources") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("SD Card") {
                            TextField("512M", text: $draft.sdCardSize)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }

                        LabeledContent("Internal Storage") {
                            TextField("6G", text: $draft.dataPartitionSize)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }

                        LabeledContent("RAM") {
                            TextField("2048", text: $draft.ramSizeMB)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }

                        LabeledContent("VM Heap") {
                            TextField("256", text: $draft.vmHeapSizeMB)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("Runtime") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("GPU Mode") {
                            Picker("GPU Mode", selection: $draft.gpuMode) {
                                ForEach(gpuModes, id: \.self) { mode in
                                    Text(mode).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }

                        LabeledContent("Network Latency") {
                            Picker("Network Latency", selection: $draft.networkLatency) {
                                ForEach(networkModes, id: \.self) { mode in
                                    Text(mode).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }

                        Toggle("Show Device Frame", isOn: $draft.showDeviceFrame)
                        Toggle("Enable Quick Boot", isOn: $draft.quickBootEnabled)
                    }
                    .padding(.top, 6)
                }

                if let selectedAVD {
                    GroupBox("Bundle") {
                        Text(selectedAVD.bundlePath.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selectedAVD?.statusSymbol ?? "plus.app")
                .font(.system(size: 26))
                .foregroundStyle(statusColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.title)
                    .font(.title2.weight(.semibold))

                Text(summarySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(selectedAVD?.statusLabel ?? "New")
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if selectedAVD != nil {
                    Button("Reveal in Finder", action: onReveal)
                    Button("Duplicate", action: onDuplicate)

                    Menu("More") {
                        Button("Wipe Data…", role: .destructive, action: onWipe)
                        Button("Delete…", role: .destructive, action: onDelete)
                    }
                }

                Spacer()

                if let selectedAVD {
                    if selectedAVD.isRunning {
                        Button("Stop", action: onStop)
                    } else {
                        Button("Launch", action: onLaunch)
                    }
                }

                Button(draft.mode.saveTitle, action: onSave)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var summarySubtitle: String {
        if let selectedAVD {
            return selectedAVD.immutableSummary
        }
        return "Create a new Android Virtual Device for your local fleet."
    }

    private var statusColor: Color {
        guard let selectedAVD else {
            return .accentColor
        }
        if !selectedAVD.isSystemImageAvailable {
            return .orange
        }
        return selectedAVD.isRunning ? .green : .secondary
    }
}
