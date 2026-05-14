import AppKit
import Foundation

import PastaCore

extension AppDelegate {
    func checkAndOfferMoveToApplications() {
        guard let bundlePath = Bundle.main.bundlePath as NSString? else { return }

        // Check if we're already in Applications
        let applicationsPath = "/Applications"
        if bundlePath.deletingLastPathComponent == applicationsPath {
            // Running from Applications - check for mounted Pasta DMG to clean up
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.checkForMountedPastaDMG()
            }
            return
        }

        // Check if running from a DMG (mounted volume)
        let volumesPrefix = "/Volumes/"
        guard bundlePath.hasPrefix(volumesPrefix) else { return }

        // Check if we've already asked the user (persists across launches via UserDefaults)
        let hasAskedKey = "pasta.hasAskedToMoveToApplications"
        if UserDefaults.standard.bool(forKey: hasAskedKey) {
            return
        }
        UserDefaults.standard.set(true, forKey: hasAskedKey)

        // Show alert after a short delay to let the app finish launching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showMoveToApplicationsAlert(bundlePath: bundlePath as String)
        }
    }

    func checkForMountedPastaDMG() {
        let fileManager = FileManager.default

        // Only show eject dialog once per volume - track which volumes we've asked about
        // This prevents the dialog from appearing after Sparkle auto-updates
        let askedVolumesKey = "pasta.askedToEjectVolumes"
        var askedVolumes = Set(UserDefaults.standard.stringArray(forKey: askedVolumesKey) ?? [])

        do {
            let volumes = try fileManager.contentsOfDirectory(atPath: "/Volumes")

            for volume in volumes {
                let volumePath = "/Volumes/\(volume)"
                let appPath = "\(volumePath)/Pasta.app"

                // Check if this looks like our Pasta DMG
                if volume.lowercased().contains("pasta") || fileManager.fileExists(atPath: appPath) {
                    // Skip if we've already asked about this volume
                    if askedVolumes.contains(volume) {
                        PastaLogger.app.debug("Already asked about volume: \(volume), skipping")
                        continue
                    }

                    // Remember we asked about this volume
                    askedVolumes.insert(volume)
                    UserDefaults.standard.set(Array(askedVolumes), forKey: askedVolumesKey)

                    showEjectDMGAlert(volumeName: volume)
                    return
                }
            }
        } catch {
            PastaLogger.app.debug("Could not check for mounted DMG: \(error.localizedDescription)")
        }
    }

    func showEjectDMGAlert(volumeName: String) {
        let alert = NSAlert()
        alert.messageText = "Eject Installer?"
        alert.informativeText = "Pasta has been installed. Would you like to eject the installer disk image and move it to Trash?"
        alert.addButton(withTitle: "Eject & Trash")
        alert.addButton(withTitle: "Just Eject")
        alert.addButton(withTitle: "Keep Mounted")
        alert.alertStyle = .informational

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            Task.detached {
                await self.ejectAndDeleteDMG(volumePath: "/Volumes/\(volumeName)")
            }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.unmountAndEjectDevice(atPath: "/Volumes/\(volumeName)")
        }
    }

    func showMoveToApplicationsAlert(bundlePath: String) {
        let alert = NSAlert()
        alert.messageText = "Move Pasta to Applications?"
        alert.informativeText = "Pasta is running from a disk image. Would you like to move it to your Applications folder for permanent installation?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")

        // Set app icon in the alert
        if let appIcon = NSApplication.shared.applicationIconImage {
            alert.icon = appIcon
        }

        // Add checkbox for deleting DMG
        let checkbox = NSButton(checkboxWithTitle: "Delete disk image after moving", target: nil, action: nil)
        checkbox.state = .on
        alert.accessoryView = checkbox

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            moveToApplications(from: bundlePath, deleteDMG: checkbox.state == .on)
        }
    }

    func moveToApplications(from sourcePath: String, deleteDMG: Bool) {
        let fileManager = FileManager.default
        let appName = (sourcePath as NSString).lastPathComponent
        let destinationPath = "/Applications/\(appName)"

        // Extract volume path for DMG deletion
        let volumePath = extractVolumePath(from: sourcePath)

        do {
            // Remove existing app if present
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }

            // Copy to Applications
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)

            PastaLogger.app.info("Successfully moved app to Applications")

            // Prepare to relaunch from new location
            let newAppURL = URL(fileURLWithPath: destinationPath)

            // Delete DMG if requested
            if deleteDMG, let volumePath = volumePath {
                // Eject the DMG (run in Task to handle actor isolation)
                Task.detached {
                    await self.ejectAndDeleteDMG(volumePath: volumePath)
                }
            }

            // Relaunch from Applications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSWorkspace.shared.openApplication(
                    at: newAppURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error = error {
                        PastaLogger.app.error("Failed to relaunch: \(error.localizedDescription)")
                    }
                }

                // Quit current instance
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }

        } catch {
            PastaLogger.app.error("Failed to move to Applications: \(error.localizedDescription)")

            let errorAlert = NSAlert()
            errorAlert.messageText = "Failed to Move"
            errorAlert.informativeText = "Could not move Pasta to Applications: \(error.localizedDescription)"
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    func extractVolumePath(from appPath: String) -> String? {
        // Extract /Volumes/VolumeName from the path
        let components = appPath.split(separator: "/")
        guard components.count >= 2,
              components[0] == "Volumes" else {
            return nil
        }
        return "/Volumes/\(components[1])"
    }

    func ejectAndDeleteDMG(volumePath: String) {
        // Find the DMG file associated with this volume
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let images = plist["images"] as? [[String: Any]] {

                for image in images {
                    if let systemEntities = image["system-entities"] as? [[String: Any]] {
                        for entity in systemEntities {
                            if let mountPoint = entity["mount-point"] as? String,
                               mountPoint == volumePath,
                               let imagePath = image["image-path"] as? String {

                                // Eject the volume
                                let ejectTask = Process()
                                ejectTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                                ejectTask.arguments = ["detach", volumePath, "-force"]
                                try ejectTask.run()
                                ejectTask.waitUntilExit()

                                // Delete the DMG file
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: imagePath), resultingItemURL: nil)
                                    PastaLogger.app.info("Moved DMG to trash: \(imagePath)")
                                }
                                return
                            }
                        }
                    }
                }
            }
        } catch {
            PastaLogger.app.error("Failed to eject/delete DMG: \(error.localizedDescription)")
        }
    }
}
