import Foundation
import Darwin

actor AndroidAVDService {
    private let fileManager = FileManager.default

    private var userHomeDirectory: URL {
        if let passwd = getpwuid(getuid()), let homeDirectory = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
        }

        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    func loadWorkspace(preferredSDKRoot: URL? = nil) throws -> AndroidWorkspaceSnapshot {
        let toolchain = discoverToolchain(preferredSDKRoot: preferredSDKRoot)
        let runningByName = try runningEmulators(toolchain: toolchain)
        let avds = try loadAVDs(toolchain: toolchain, runningByName: runningByName)
        let devices = try loadDeviceDefinitions(toolchain: toolchain)
        let systemImages = try loadInstalledSystemImages(toolchain: toolchain)
        return AndroidWorkspaceSnapshot(
            toolchain: toolchain,
            avds: avds.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            devices: devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            systemImages: systemImages.sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
        )
    }

    func resolveToolchain(preferredSDKRoot: URL? = nil) -> AndroidToolchain {
        discoverToolchain(preferredSDKRoot: preferredSDKRoot)
    }

    func discoverSDKRootCandidate() -> URL? {
        discoverToolchain().sdkRoot
    }

    func sdkRootSearchLocations() -> [URL] {
        uniqueSDKCandidates()
    }

    func saveDraft(_ draft: AVDEditorDraft, toolchain: AndroidToolchain) throws {
        guard let avdManagerURL = toolchain.avdManagerURL else {
            throw AndroidAVDError.toolNotFound("avdmanager")
        }

        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AndroidAVDError.invalidDraft("An AVD name is required.")
        }
        guard !draft.deviceID.isEmpty else {
            throw AndroidAVDError.invalidDraft("Choose a device profile.")
        }
        guard !draft.systemImagePackage.isEmpty else {
            throw AndroidAVDError.invalidDraft("Choose an installed system image.")
        }

        switch draft.mode {
        case .create, .duplicate:
            var arguments = ["create", "avd", "-n", trimmedName, "-k", draft.systemImagePackage, "-d", draft.deviceID, "-f"]
            if !draft.sdCardSize.isEmpty {
                arguments.append(contentsOf: ["-c", draft.sdCardSize])
            }
            _ = try runCommand(
                executable: avdManagerURL,
                arguments: arguments,
                input: "no\n"
            )
            try applyMutableSettings(to: trimmedName, using: draft, toolchain: toolchain)

        case .edit(let originalName):
            if draft.deviceID != draft.originalDeviceID || draft.systemImagePackage != draft.originalSystemImagePackage {
                throw AndroidAVDError.immutableFieldChange
            }

            var activeName = originalName
            if trimmedName != originalName {
                _ = try runCommand(
                    executable: avdManagerURL,
                    arguments: ["move", "avd", "-n", originalName, "-r", trimmedName]
                )
                activeName = trimmedName
            }
            try applyMutableSettings(to: activeName, using: draft, toolchain: toolchain)
        }
    }

    func deleteAVD(_ avd: AndroidVirtualDevice, toolchain: AndroidToolchain) throws {
        if let serial = avd.runningSerial {
            try stopAVD(serial: serial, toolchain: toolchain)
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let avdManagerURL = toolchain.avdManagerURL else {
            throw AndroidAVDError.toolNotFound("avdmanager")
        }
        _ = try runCommand(executable: avdManagerURL, arguments: ["delete", "avd", "-n", avd.name])
    }

    func launchAVD(named name: String, coldBoot: Bool, wipeData: Bool, toolchain: AndroidToolchain) throws {
        guard let emulatorURL = toolchain.emulatorURL else {
            throw AndroidAVDError.toolNotFound("emulator")
        }

        var arguments = ["@\(name)"]
        if coldBoot {
            arguments.append("-no-snapshot-load")
        }
        if wipeData {
            arguments.append("-wipe-data")
        }
        try launchDetached(executable: emulatorURL, arguments: arguments)
    }

    func stopAVD(serial: String, toolchain: AndroidToolchain) throws {
        guard let adbURL = toolchain.adbURL else {
            throw AndroidAVDError.toolNotFound("adb")
        }
        _ = try runCommand(executable: adbURL, arguments: ["-s", serial, "emu", "kill"])
    }

    func wipeData(for avd: AndroidVirtualDevice) throws {
        guard fileManager.fileExists(atPath: avd.bundlePath.path) else {
            throw AndroidAVDError.missingBundlePath
        }
        guard avd.runningSerial == nil else {
            throw AndroidAVDError.invalidDraft("Stop the emulator before wiping its data.")
        }

        let removableFiles = [
            "bootcompleted.ini",
            "cache.img",
            "cache.img.qcow2",
            "encryptionkey.img",
            "encryptionkey.img.qcow2",
            "multiinstance.lock",
            "read-snapshot.txt",
            "userdata-qemu.img",
            "userdata-qemu.img.qcow2"
        ]

        for file in removableFiles {
            let candidate = avd.bundlePath.appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
        }

        let snapshots = avd.bundlePath.appendingPathComponent("snapshots")
        if fileManager.fileExists(atPath: snapshots.path) {
            try fileManager.removeItem(at: snapshots)
        }
    }

    private func applyMutableSettings(to avdName: String, using draft: AVDEditorDraft, toolchain: AndroidToolchain) throws {
        let avd = try loadAVD(named: avdName, toolchain: toolchain, runningSerial: nil)
        let configURL = avd.bundlePath.appendingPathComponent("config.ini")
        var configuration = try parseKeyValueFile(at: configURL)

        configuration["AvdId"] = avdName
        configuration["avd.ini.displayname"] = draft.displayName.isEmpty ? humanize(avdName) : draft.displayName
        configuration["disk.dataPartition.size"] = draft.dataPartitionSize
        configuration["fastboot.forceColdBoot"] = draft.quickBootEnabled ? "no" : "yes"
        configuration["fastboot.forceFastBoot"] = draft.quickBootEnabled ? "yes" : "no"
        configuration["hw.ramSize"] = draft.ramSizeMB
        configuration["hw.gpu.mode"] = draft.gpuMode
        configuration["runtime.network.latency"] = draft.networkLatency
        configuration["sdcard.size"] = draft.sdCardSize
        configuration["showDeviceFrame"] = draft.showDeviceFrame ? "yes" : "no"
        configuration["vm.heapSize"] = draft.vmHeapSizeMB

        try writeKeyValueFile(configuration, to: configURL)
    }

    private func loadAVDs(toolchain: AndroidToolchain, runningByName: [String: String]) throws -> [AndroidVirtualDevice] {
        let avdRoot = userHomeDirectory
            .appendingPathComponent(".android")
            .appendingPathComponent("avd")

        guard fileManager.fileExists(atPath: avdRoot.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(at: avdRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ini" }

        return try entries.compactMap { iniURL in
            let ini = try parseKeyValueFile(at: iniURL)
            guard let bundlePathString = ini["path"] else {
                return nil
            }

            let name = iniURL.deletingPathExtension().lastPathComponent
            return try loadAVD(
                named: name,
                bundlePath: URL(fileURLWithPath: bundlePathString),
                toolchain: toolchain,
                runningSerial: runningByName[name]
            )
        }
    }

    private func loadAVD(named name: String, toolchain: AndroidToolchain, runningSerial: String?) throws -> AndroidVirtualDevice {
        let iniURL = userHomeDirectory
            .appendingPathComponent(".android")
            .appendingPathComponent("avd")
            .appendingPathComponent("\(name).ini")
        let ini = try parseKeyValueFile(at: iniURL)
        guard let bundlePathString = ini["path"] else {
            throw AndroidAVDError.missingBundlePath
        }
        return try loadAVD(
            named: name,
            bundlePath: URL(fileURLWithPath: bundlePathString),
            toolchain: toolchain,
            runningSerial: runningSerial
        )
    }

    private func loadAVD(named name: String, bundlePath: URL, toolchain: AndroidToolchain, runningSerial: String?) throws -> AndroidVirtualDevice {
        let configURL = bundlePath.appendingPathComponent("config.ini")
        let config = try parseKeyValueFile(at: configURL)

        let systemImageRelative = config["image.sysdir.1"] ?? ""
        let systemImagePackage = systemImagePackage(from: systemImageRelative)
        let systemImageAvailable: Bool
        if let sdkRoot = toolchain.sdkRoot {
            let fullSystemImagePath = sdkRoot.appendingPathComponent(systemImageRelative)
            systemImageAvailable = systemImageRelative.isEmpty ? false : fileManager.fileExists(atPath: fullSystemImagePath.path)
        } else {
            systemImageAvailable = false
        }

        return AndroidVirtualDevice(
            name: name,
            displayName: config["avd.ini.displayname"] ?? humanize(name),
            bundlePath: bundlePath,
            deviceName: config["hw.device.name"] ?? "",
            manufacturer: config["hw.device.manufacturer"] ?? "",
            systemImagePackage: systemImagePackage,
            target: config["target"] ?? "",
            tagID: config["tag.id"] ?? "",
            tagDisplay: config["tag.display"] ?? "",
            abi: config["abi.type"] ?? "",
            skinName: config["skin.name"] ?? "",
            sdCardSize: config["sdcard.size"] ?? "",
            dataPartitionSize: config["disk.dataPartition.size"] ?? "",
            ramSizeMB: config["hw.ramSize"] ?? "",
            vmHeapSizeMB: config["vm.heapSize"] ?? "",
            gpuMode: config["hw.gpu.mode"] ?? "auto",
            networkLatency: config["runtime.network.latency"] ?? "none",
            showDeviceFrame: config["showDeviceFrame"]?.lowercased() != "no",
            quickBootEnabled: config["fastboot.forceColdBoot"]?.lowercased() != "yes",
            config: config,
            runningSerial: runningSerial,
            isSystemImageAvailable: systemImageAvailable
        )
    }

    private func loadInstalledSystemImages(toolchain: AndroidToolchain) throws -> [InstalledSystemImage] {
        guard let sdkManagerURL = toolchain.sdkManagerURL else {
            return []
        }

        let result = try runCommand(executable: sdkManagerURL, arguments: ["--list_installed"])
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("system-images;") else {
                    return nil
                }
                let columns = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard columns.count >= 4 else {
                    return nil
                }
                return InstalledSystemImage(
                    packagePath: columns[0],
                    version: columns[1],
                    description: columns[2],
                    location: columns[3]
                )
            }
    }

    private func loadDeviceDefinitions(toolchain: AndroidToolchain) throws -> [DeviceDefinition] {
        guard let avdManagerURL = toolchain.avdManagerURL else {
            return []
        }

        let result = try runCommand(executable: avdManagerURL, arguments: ["list", "device"])
        let blocks = result.stdout.components(separatedBy: "---------")
        return blocks.compactMap { block in
            let lines = block
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard let idLine = lines.first(where: { $0.hasPrefix("id:") }),
                  let nameLine = lines.first(where: { $0.hasPrefix("Name:") }),
                  let oemLine = lines.first(where: { $0.hasPrefix("OEM") }) else {
                return nil
            }

            let id = quotedValue(in: idLine) ?? ""
            let name = nameLine.replacingOccurrences(of: "Name:", with: "").trimmingCharacters(in: .whitespaces)
            let oem = oemLine.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            let tagLine = lines.first(where: { $0.hasPrefix("Tag") })
            let tag = tagLine?.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            guard !id.isEmpty else {
                return nil
            }
            return DeviceDefinition(id: id, name: name, oem: oem, tag: tag)
        }
    }

    private func runningEmulators(toolchain: AndroidToolchain) throws -> [String: String] {
        guard let adbURL = toolchain.adbURL else {
            return [:]
        }

        let devices = try runCommand(executable: adbURL, arguments: ["devices", "-l"])
        let serials = devices.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.hasPrefix("emulator-") }
            .compactMap { $0.split(separator: " ").first.map(String.init) }

        var mapping: [String: String] = [:]
        for serial in serials {
            if let name = try? runCommand(executable: adbURL, arguments: ["-s", serial, "emu", "avd", "name"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                mapping[name] = serial
            }
        }
        return mapping
    }

    private func discoverToolchain(preferredSDKRoot: URL? = nil) -> AndroidToolchain {
        if let preferredSDKRoot {
            let normalizedRoot = preferredSDKRoot.standardizedFileURL
            return AndroidToolchain(
                sdkRoot: normalizedRoot,
                avdManagerURL: executableURL(
                    fallbackName: "avdmanager",
                    sdkRoot: normalizedRoot,
                    sdkRelativePath: "cmdline-tools/latest/bin/avdmanager",
                    allowPathFallback: false
                ),
                emulatorURL: executableURL(
                    fallbackName: "emulator",
                    sdkRoot: normalizedRoot,
                    sdkRelativePath: "emulator/emulator",
                    allowPathFallback: false
                ),
                adbURL: executableURL(
                    fallbackName: "adb",
                    sdkRoot: normalizedRoot,
                    sdkRelativePath: "platform-tools/adb",
                    allowPathFallback: false
                ),
                sdkManagerURL: executableURL(
                    fallbackName: "sdkmanager",
                    sdkRoot: normalizedRoot,
                    sdkRelativePath: "cmdline-tools/latest/bin/sdkmanager",
                    allowPathFallback: false
                )
            )
        }

        let environment = ProcessInfo.processInfo.environment
        let sdkCandidates = uniqueSDKCandidates(environment: environment)

        let sdkRoot = sdkCandidates.first { fileManager.fileExists(atPath: $0.path) }

        return AndroidToolchain(
            sdkRoot: sdkRoot,
            avdManagerURL: executableURL(
                fallbackName: "avdmanager",
                sdkRoot: sdkRoot,
                sdkRelativePath: "cmdline-tools/latest/bin/avdmanager",
                allowPathFallback: true
            ),
            emulatorURL: executableURL(
                fallbackName: "emulator",
                sdkRoot: sdkRoot,
                sdkRelativePath: "emulator/emulator",
                allowPathFallback: true
            ),
            adbURL: executableURL(
                fallbackName: "adb",
                sdkRoot: sdkRoot,
                sdkRelativePath: "platform-tools/adb",
                allowPathFallback: true
            ),
            sdkManagerURL: executableURL(
                fallbackName: "sdkmanager",
                sdkRoot: sdkRoot,
                sdkRelativePath: "cmdline-tools/latest/bin/sdkmanager",
                allowPathFallback: true
            )
        )
    }

    private func executableURL(
        fallbackName: String,
        sdkRoot: URL?,
        sdkRelativePath: String,
        allowPathFallback: Bool
    ) -> URL? {
        if let sdkRoot {
            let candidate = sdkRoot.appendingPathComponent(sdkRelativePath)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        guard allowPathFallback else {
            return nil
        }

        let result = try? runCommand(executable: URL(fileURLWithPath: "/usr/bin/which"), arguments: [fallbackName], allowFailure: true)
        guard let path = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func uniqueSDKCandidates(environment: [String: String]? = nil) -> [URL] {
        let environment = environment ?? ProcessInfo.processInfo.environment
        let candidates = [
            environment["ANDROID_SDK_ROOT"],
            environment["ANDROID_HOME"],
            userHomeDirectory.appendingPathComponent("Library/Android/sdk").path
        ]
            .compactMap { $0 }
            .map(URL.init(fileURLWithPath:))

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func parseKeyValueFile(at url: URL) throws -> [String: String] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AndroidAVDError.missingBundlePath
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            values[key] = value
        }
        return values
    }

    private func writeKeyValueFile(_ values: [String: String], to url: URL) throws {
        let original = try String(contentsOf: url, encoding: .utf8)
        var remaining = values
        var output: [String] = []

        for rawLine in original.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else {
                output.append(line)
                continue
            }

            let key = String(line[..<separator])
            if let value = remaining.removeValue(forKey: key) {
                output.append("\(key)=\(value)")
            } else {
                output.append(line)
            }
        }

        for key in remaining.keys.sorted() {
            output.append("\(key)=\(remaining[key] ?? "")")
        }

        try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func systemImagePackage(from relativePath: String) -> String {
        let cleaned = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else {
            return ""
        }
        return cleaned.replacingOccurrences(of: "/", with: ";")
    }

    private func humanize(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func quotedValue(in line: String) -> String? {
        guard let firstQuote = line.firstIndex(of: "\""),
              let lastQuote = line.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return nil
        }
        return String(line[line.index(after: firstQuote)..<lastQuote])
    }

    private func runCommand(
        executable: URL,
        arguments: [String],
        input: String? = nil,
        allowFailure: Bool = false
    ) throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let input {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let result = CommandResult(stdout: stdout, stderr: stderr, terminationStatus: process.terminationStatus)

        if process.terminationStatus != 0 && !allowFailure {
            let message = [stderr.trimmingCharacters(in: .whitespacesAndNewlines), stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
                .first(where: { !$0.isEmpty }) ?? "Command failed."
            throw AndroidAVDError.commandFailed(message)
        }

        return result
    }

    private func launchDetached(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = nil
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

private struct CommandResult {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}
