// Disposable updater integration driver, never linked into Storage Saver.
import AppKit
import Sparkle

final class FixtureDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
  let label = NSTextField(labelWithString: "Disposable Storage Saver updater test")
  var window: NSWindow!
  var updater: SPUUpdater!
  let target: Bundle
  let output: URL
  var events = [String]()
  var overrideFeed: URL?
  func feedURLString(for updater: SPUUpdater) -> String? { overrideFeed?.absoluteString }
  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
  init(target: Bundle, output: URL) { self.target = target; self.output = output; super.init() }
  func event(_ value: String) { events.append(value); label.stringValue = value; print(value); fflush(stdout) }
  func finish(_ ok: Bool, _ error: Error? = nil) {
    let object: [String: Any] = ["passed": ok, "events": events, "error": error.map(String.init(describing:)) ?? "", "target": target.bundleURL.path]
    try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: output)
    NSApp.terminate(nil)
  }
  func start(feed: URL?) throws {
    window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 520,height: 100),styleMask: [.titled,.closable],backing: .buffered,defer: false)
    window.title = "Disposable updater verification"
    window.contentView = label;window.orderBack(nil)
    overrideFeed = feed
    updater = SPUUpdater(hostBundle: target, applicationBundle: target, userDriver: self, delegate: self)
    try updater.start()
    updater.checkForUpdates()
  }
  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { event("checking") }
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { event("found " + appcastItem.displayVersionString);reply(.install) }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { event("no-update");acknowledgement();finish(false,error) }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { event("failed");acknowledgement();finish(false,error) }
  func showDownloadInitiated(cancellation: @escaping () -> Void) { event("downloading") }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
  func showDownloadDidReceiveData(ofLength length: UInt64) {}
  func showDownloadDidStartExtractingUpdate() { event("extracting verified update") }
  func showExtractionReceivedProgress(_ progress: Double) {}
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { event("ready to install");reply(.install) }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { event("installing") }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { event("installed");acknowledgement();finish(true) }
  func dismissUpdateInstallation() {}
}
let args = CommandLine.arguments
precondition(args.count >= 3)
let app = URL(fileURLWithPath: args[1]).standardizedFileURL
precondition(args.count >= 5, "Explicit disposable fixture root required")
let fixtureRoot = URL(fileURLWithPath: args[4]).resolvingSymlinksInPath()
precondition(fixtureRoot.deletingLastPathComponent().lastPathComponent == ".local" && fixtureRoot.lastPathComponent.range(of: "^updater-e2e-[0-9a-f]{12}$", options: .regularExpression) != nil, "Invalid disposable fixture root")
precondition(app.resolvingSymlinksInPath().path.hasPrefix(fixtureRoot.path + "/") && FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent(".fixture-owner").path), "Only owned disposable fixture apps may be updated")
let output = URL(fileURLWithPath: args[2])
let driver = FixtureDriver(target: Bundle(url: app)!, output: output)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
DispatchQueue.main.async {
  do { try driver.start(feed: args.count > 3 ? URL(string: args[3]) : nil) }
  catch { driver.finish(false,error) }
}
DispatchQueue.main.asyncAfter(deadline: .now()+180) { driver.event("timeout");driver.finish(false,NSError(domain:"FixtureDeadline",code:124)) }
application.run()
