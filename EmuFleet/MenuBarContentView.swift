import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: AVDStore
    @Environment(\.openWindow) private var openWindow

    @State private var deleteCandidate: AndroidVirtualDevice?
    @State private var wipeCandidate: AndroidVirtualDevice?

    var body: some View {
        Group {
            if store.needsSDKSetup {
                SDKSetupView(compact: true)
            } else {
                VStack(spacing: 0) {
                    titleBar
                    Divider()
                    filterBar
                    content
                    Divider()
                    footer
                }
            }
        }
        .frame(width: 420)
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
            Text("This removes the emulator's writable data images. The device definition stays intact.")
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

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: store.hasRunningAVD ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("EmuFleet")
                    .font(.headline)
                Text("\(store.avds.count) virtual devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.beginCreateDraft()
                openWindow(id: "manager")
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Create a new AVD")

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh AVD state")

            Button("Manager…") {
                openWindow(id: "manager")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Search AVDs", text: $store.searchText)
                .textFieldStyle(.roundedBorder)

            Menu {
                Picker("Show", selection: $store.filter) {
                    ForEach(AVDFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                Label(store.filter.title, systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .help("Filter device list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if store.filteredAVDs.isEmpty {
            ContentUnavailableView(
                "No Matching AVDs",
                systemImage: "square.stack.3d.down.right",
                description: Text("Adjust the search or create a new Android Virtual Device.")
            )
            .frame(maxWidth: .infinity, minHeight: 250)
            .padding(.horizontal, 12)
        } else {
            List {
                ForEach(store.filteredAVDs) { avd in
                    MenuBarAVDRow(
                        avd: avd,
                        onOpen: {
                            store.selectAVD(named: avd.name)
                            openWindow(id: "manager")
                        },
                        onPrimaryAction: {
                            Task {
                                if avd.isRunning {
                                    await store.stop(avd)
                                } else {
                                    await store.launch(avd)
                                }
                            }
                        },
                        onDuplicate: {
                            store.beginDuplicateDraft(from: avd)
                            openWindow(id: "manager")
                        },
                        onColdBoot: {
                            Task { await store.launch(avd, coldBoot: true) }
                        },
                        onReveal: {
                            store.revealInFinder(avd)
                        },
                        onWipe: {
                            wipeCandidate = avd
                        },
                        onDelete: {
                            deleteCandidate = avd
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
            .listStyle(.inset)
            .frame(height: 300)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.toolchain.isReady ? "Android SDK ready" : "Android SDK unavailable")
                    .font(.caption.weight(.semibold))
                Text(footerSubtitle)
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
    }

    private var footerSubtitle: String {
        if let lastRefreshDate {
            return "Updated \(lastRefreshDate.formatted(date: .omitted, time: .shortened))"
        }
        return store.toolchain.sdkRootDisplay
    }

    private var lastRefreshDate: Date? {
        store.lastRefreshDate
    }
}

private struct MenuBarAVDRow: View {
    let avd: AndroidVirtualDevice
    let onOpen: () -> Void
    let onPrimaryAction: () -> Void
    let onDuplicate: () -> Void
    let onColdBoot: () -> Void
    let onReveal: () -> Void
    let onWipe: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: avd.statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(avd.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(avd.isSystemImageAvailable ? avd.subtitle : "System image missing")
                    .font(.caption)
                    .foregroundStyle(avd.isSystemImageAvailable ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(avd.statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)

            Button(avd.isRunning ? "Stop" : "Launch", action: onPrimaryAction)
                .controlSize(.small)

            Menu {
                Button("Open in Manager", action: onOpen)
                Button("Duplicate", action: onDuplicate)
                Button("Cold Boot", action: onColdBoot)
                Button("Reveal in Finder", action: onReveal)
                Divider()
                Button("Wipe Data…", role: .destructive, action: onWipe)
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .help("More actions")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open in Manager", action: onOpen)
            Button("Duplicate", action: onDuplicate)
            Button("Cold Boot", action: onColdBoot)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Wipe Data…", role: .destructive, action: onWipe)
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private var statusColor: Color {
        if !avd.isSystemImageAvailable {
            return .orange
        }
        return avd.isRunning ? .green : .secondary
    }
}
