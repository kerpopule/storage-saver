import AppKit
import Sparkle

func scanBlocksApplicationTermination(_ dataURL: URL) -> Bool {
  guard let bytes = try? Data(contentsOf: dataURL.appendingPathComponent("progress.json")),
    let p = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
    p["state"] as? String == "scanning", let pid = p["pid"] as? Int32, pid > 0 else { return false }
  let result = Darwin.kill(pid, 0)
  // A root-owned scanner is alive even when an ordinary caller cannot signal it.
  return result == 0 || errno == EPERM
}

extension Desktop {
  func configureUpdates(menu: NSMenu) {
    let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    check.target = self
    menu.addItem(check)
    let automatic = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
    automatic.target = self
    menu.addItem(automatic)
    menu.addItem(.separator())
    // Synthetic native fixtures do not contact the public update service.
    guard !fixture else { return }
    updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }
  @objc func checkForUpdates() {
    updaterController?.checkForUpdates(nil)
  }
  @objc func toggleAutomaticUpdates(_ sender: NSMenuItem) {
    guard let updater = updaterController?.updater else { return }
    updater.automaticallyChecksForUpdates.toggle()
    sender.state = updater.automaticallyChecksForUpdates ? .on : .off
  }
}
extension Desktop: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(checkForUpdates) { return updaterController?.updater.canCheckForUpdates ?? false }
    if item.action == #selector(toggleAutomaticUpdates(_:)) {
      item.state = updaterController?.updater.automaticallyChecksForUpdates == true ? .on : .off
      return updaterController != nil
    }
    return true
  }
}
