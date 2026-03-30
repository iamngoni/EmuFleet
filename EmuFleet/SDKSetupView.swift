import SwiftUI

struct SDKSetupView: View {
    @EnvironmentObject private var store: AVDStore

    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: compact ? 24 : 30))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Set Up Android SDK")
                        .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    Text(store.sdkSetup.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox("SDK Root") {
                VStack(alignment: .leading, spacing: 8) {
                    if let proposedSDKRoot = store.sdkSetup.proposedSDKRoot {
                        Text(proposedSDKRoot.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("No SDK path detected yet.")
                            .foregroundStyle(.secondary)
                    }

                    if let detail = store.sdkSetup.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !store.sdkSetup.scannedLocations.isEmpty {
                        Divider()
                            .padding(.vertical, 2)

                        Text("Scanned")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.sdkSetup.scannedLocations, id: \.self) { location in
                                Text(location)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }

            HStack(spacing: 10) {
                if store.sdkSetup.proposedSDKRoot != nil {
                    Button("Use This Path") {
                        Task { await store.confirmProposedSDKRoot() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isConfiguringSDK)
                }

                Button(store.sdkSetup.proposedSDKRoot == nil ? "Choose SDK Folder…" : "Choose Different Folder…") {
                    store.chooseCustomSDKRoot()
                }
                .disabled(store.isConfiguringSDK)

                Button("Refresh Detection") {
                    Task { await store.refreshSDKDetection() }
                }
                .disabled(store.isConfiguringSDK)

                Spacer()

                if store.isConfiguringSDK {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(compact ? 14 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
