import AppKit
import Darwin
import Foundation
import WebKit
import Sparkle

func jsonData(_ v: Any) -> Data {
  (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data("{}".utf8)
}
func arg(_ name: String) -> String? {
  guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count
  else { return nil }
  return CommandLine.arguments[i + 1]
}
func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

final class Desktop: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
  let fm = FileManager.default
  let grants = GrantStore()
  let elevatedSessions = ElevatedSessions()
  let queue = DispatchQueue(label: "StorageSaver.AgentBroker")
  var window: NSWindow!
  var web: WKWebView!
  var child: Process?
  var updaterController: SPUStandardUpdaterController?
  var socketFD: Int32 = -1
  var lockFD: Int32 = -1
  let home = FileManager.default.homeDirectoryForCurrentUser
  var dataURL: URL {
    URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["STORAGE_SAVER_DATA"]
        ?? home.appendingPathComponent("Library/Application Support/StorageAtlas").path)
  }
  var port: Int {
    Int(ProcessInfo.processInfo.environment["STORAGE_SAVER_PORT"] ?? "43127") ?? 43127
  }
  var engine: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/storage-atlas") }
  var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
  var fixture: Bool { ProcessInfo.processInfo.environment["STORAGE_SAVER_FIXTURE_ROOT"] != nil }
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataURL.path)
      lockFD = Darwin.open(
        dataURL.appendingPathComponent("native.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
      try require(
        lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0,
        "Storage Saver is already running for this catalog")
      try startSocket()
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController.add(self, name: "storageSaver")
      web = WKWebView(
        frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: configuration)
      web.navigationDelegate = self
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "Storage Saver"
      window.minSize = NSSize(width: 720, height: 560)
      window.contentView = web
      window.center()
      let menu = NSMenu()
      let root = NSMenuItem()
      let appMenu = NSMenu()
      appMenu.addItem(withTitle: "About Storage Saver", action: #selector(about), keyEquivalent: "")
      appMenu.addItem(.separator())
      configureUpdates(menu: appMenu)
      appMenu.addItem(
        withTitle: "Quit Storage Saver", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q")
      root.submenu = appMenu
      menu.addItem(root)
      NSApp.mainMenu = menu
      if !fixture {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
      } else {
        window.orderBack(nil)
      }
      connect(attempt: 0)
      if fixture { DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NSApp.terminate(nil) } }
    } catch {
      alert("Storage Saver could not start", String(describing: error))
      NSApp.terminate(nil)
    }
  }
  @objc func about() {
    alert(
      "Storage Saver",
      "Private local inventory for humans and AI. Physical data measurements count APFS shared extents once. Agent file access requires an explicit, scoped, temporary grant. No permanent-deletion endpoint."
    )
  }
  func connect(attempt: Int) {
    var request = URLRequest(url: base.appendingPathComponent("api/invite"))
    request.timeoutInterval = 2
    URLSession.shared.dataTask(with: request) { data, _, _ in
      let good =
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["product"]
        as? String == "Storage Saver"
      DispatchQueue.main.async {
        if good {
          self.web.load(URLRequest(url: self.base))
          return
        }
        if attempt == 0 {
          do { try self.startEngine() } catch {
            self.alert("Engine unavailable", String(describing: error))
            return
          }
        }
        if attempt < 30 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.connect(attempt: attempt + 1)
          }
        } else {
          self.alert(
            "Engine unavailable",
            "Could not connect to the bundled local engine. No browser or public server was opened."
          )
        }
      }
    }.resume()
  }
  func startEngine() throws {
    let p = Process()
    p.executableURL = engine
    var args = ["--data", dataURL.path]
    if let root = ProcessInfo.processInfo.environment["STORAGE_SAVER_FIXTURE_ROOT"] {
      args += ["--root", root]
    }
    p.arguments = args + ["serve", "--port", String(port), "--interval", "21600"]
    let log = dataURL.appendingPathComponent("desktop-engine.log")
    if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: Data()) }
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    p.standardOutput = handle
    p.standardError = handle
    try p.run()
    child = p
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if scanBlocksApplicationTermination(dataURL) {
      alert("Scan in progress", "Wait for the current scan to finish before quitting or installing an update. Your existing complete index remains available.")
      return .terminateCancel
    }
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    grants.revokeAll()
    elevatedSessions.revokeAll()
    if let p = child, p.isRunning { p.terminate() }
    if socketFD >= 0 {
      Darwin.close(socketFD)
      try? fm.removeItem(at: dataURL.appendingPathComponent("agent.sock"))
    }
    if lockFD >= 0 { Darwin.close(lockFD) }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let u = navigationAction.request.url
    decisionHandler(
      u?.scheme == "http" && u?.host == "127.0.0.1" && u?.port == port ? .allow : .cancel)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard fixture else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.fixtureProof() }
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "127.0.0.1",
      message.frameInfo.securityOrigin.port == port, let body = message.body as? [String: Any],
      let action = body["action"] as? String
    else { return }
    switch action {
    case "invite": showInvitation()
    case "grantOrdinary": grant(elevated: false)
    case "grantElevated": grant(elevated: true)
    case "manageGrants": manage()
    default: break
    }
  }
  func alert(_ title: String, _ message: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.addButton(withTitle: "OK")
    a.runModal()
  }
  func grant(elevated: Bool) {
    let picker = NSOpenPanel()
    picker.title =
      elevated
      ? "Select folders for elevated agent access" : "Select folders for ordinary agent access"
    picker.canChooseFiles = false
    picker.canChooseDirectories = true
    picker.allowsMultipleSelection = true
    picker.prompt = "Choose scope"
    guard picker.runModal() == .OK else { return }
    let a = NSAlert()
    a.messageText = elevated ? "Allow elevated agent access" : "Allow ordinary agent access"
    a.informativeText =
      "Access is limited to the selected folders and expires after 30 minutes or when this app quits. View permits listing, metadata and small file reads. Edit additionally permits creating new files/folders, verified copies and non-overwriting same-volume moves. Replacing a small text file requires its current SHA-256 and retains the original as a backup. Other writes and moves cannot overwrite existing files. Permanent deletion is not exposed.\n\n"
      + (elevated
        ? "Authenticate with macOS once for this folder-scoped session. Authorized requests then run without repeated approval until expiry, Revoke all, or app exit. Failed sessions never automatically reopen authentication. This cannot override Full Disk Access or protected macOS paths."
        : "The agent uses this app's ordinary filesystem permissions. macOS privacy restrictions still apply.")
      + "\n\nRevocation stops new requests, not already-running operations."
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    let rights = NSPopUpButton()
    rights.addItems(withTitles: ["View only", "Edit: create, backed-up replace, copy and move"])
    let ack = NSButton(
      checkboxWithTitle: "I accept responsibility for the scopes and actions I authorize.",
      target: nil, action: nil)
    let text = NSTextField(
      wrappingLabelWithString:
        "AI agents can disclose private data or cause unwanted changes or loss. Review the agent and every selected folder. Keep verified backups. You are responsible for your permission choices and authorized actions. This warning is not a guarantee of recovery or a replacement for macOS consent."
    )
    text.preferredMaxLayoutWidth = 470
    stack.addArrangedSubview(rights)
    stack.addArrangedSubview(text)
    stack.addArrangedSubview(ack)
    stack.frame = NSRect(x: 0, y: 0, width: 490, height: 160)
    a.accessoryView = stack
    a.addButton(withTitle: "Grant access")
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    do {
      let g = try grants.add(
        roots: picker.urls.map { $0.path }, edit: rights.indexOfSelectedItem == 1,
        elevated: elevated, ack: ack.state == .on)
      if elevated {
        do {
          let session = try startElevatedSession(grant: g, executable: Bundle.main.executablePath!) { command in
            // Authenticate exactly once at grant creation. The helper connects back on
            // a private channel and exits on disconnect or the original grant deadline.
            let background = command + " </dev/null >/dev/null 2>&1 & /usr/bin/printf '{\"ok\":true}'"
            let source = "do shell script \"" + background.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw BrokerFailure("Cannot create administrator session") }
            _ = try decodePrivilegedReply(script.executeAndReturnError(&error).stringValue, error: error)
          }
          elevatedSessions.insert(session, token: g.token)
        } catch {
          grants.revoke(g.token)
          throw error
        }
      }
      showInvitation(grant: g)
    } catch { alert("Access not granted", String(describing: error)) }
  }
  func manage() {
    let active = grants.all()
    let a = NSAlert()
    a.messageText = "Agent permissions"
    a.informativeText =
      active.isEmpty
      ? "No active file-access grants. The inventory CLI remains read-only."
      : active.map {
        "\($0.elevated ? "Elevated":"Ordinary") · \($0.edit ? "Edit":"View") · expires \($0.expires.formatted())\n\($0.roots.joined(separator:"\n"))"
      }.joined(separator: "\n\n")
    a.addButton(withTitle: "Close")
    if !active.isEmpty { a.addButton(withTitle: "Revoke all") }
    if a.runModal() == .alertSecondButtonReturn {
      grants.revokeAll()
      elevatedSessions.revokeAll()
      alert("Revoked", "All agent file grants have been revoked. New requests will be denied.")
    }
  }
  func invitation(grant: AgentGrant? = nil) throws -> String {
    let p = Process()
    p.executableURL = engine
    p.arguments = ["--data", dataURL.path, "invite", "--json"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try p.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let o = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let s = o["text"] as? String
    else { throw BrokerFailure("Could not generate invitation") }
    guard let g = grant else {
      return s
        + "\n\nNo file-access grant is attached. Ask me to grant selected folders in the desktop app if contents or edits are needed."
    }
    return s + "\n\nPRIVATE CAPABILITY, do not publish or log:\nexport STORAGE_SAVER_GRANT="
      + shellQuote(g.token) + "\nScope: " + g.roots.joined(separator: ", ")
      + "\nRights: \(g.edit ? "Edit: list/stat/read/write_new/mkdir/copy/move/replace":"View: list/stat/read"); \(g.elevated ? "Elevated session, already authenticated; no per-action approval":"Ordinary"). Expires: \(g.expires.formatted()). The desktop app must remain open. Never use this token outside the selected scopes. An expired, revoked or failed session requires a new owner-created grant; never loop or retry authentication."
  }
  func showInvitation(grant: AgentGrant? = nil) {
    do {
      let text = try invitation(grant: grant)
      let a = NSAlert()
      a.messageText = "Invite an agent"
      a.informativeText =
        grant == nil
        ? "Copy this into any AI harness running on this Mac or an authorized shell. Index access only; file grants are separate."
        : "This invitation contains a scoped, temporary file-access capability. Share it only with the agent you selected."
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 340))
      scroll.hasVerticalScroller = true
      let view = NSTextView(frame: scroll.bounds)
      view.isEditable = false
      view.isSelectable = true
      view.string = text
      view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      scroll.documentView = view
      a.accessoryView = scroll
      a.addButton(withTitle: "Copy invitation")
      a.addButton(withTitle: "Close")
      if a.runModal() == .alertFirstButtonReturn {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
    } catch { alert("Invitation unavailable", String(describing: error)) }
  }
  func startSocket() throws {
    let path = dataURL.appendingPathComponent("agent.sock").path
    try require(path.utf8.count < 104, "Private state path is too long for the local agent socket")
    if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
    socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    try require(socketFD >= 0, "Could not create agent socket")
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
      p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
    }
    let result = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try require(
      result == 0 && chmod(path, 0o600) == 0 && listen(socketFD, 8) == 0,
      "Could not bind private agent socket")
    queue.async { [weak self] in
      guard let self = self else { return }
      while self.socketFD >= 0 {
        let fd = accept(self.socketFD, nil, nil)
        if fd < 0 { break }
        self.serveClient(fd)
        Darwin.close(fd)
      }
    }
  }
  func serveClient(_ fd: Int32) {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 && uid == getuid() else { return }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var bytes = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while bytes.count <= 65536 {
      let n = Darwin.read(fd, &buf, buf.count)
      if n <= 0 { break }
      bytes.append(contentsOf: buf.prefix(n))
      if bytes.contains(10) { break }
    }
    var response: [String: Any]
    do {
      try require(bytes.count <= 65536, "Request exceeds limit")
      guard let r = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let token = r["token"] as? String
      else { throw BrokerFailure("Private grant required") }
      let g = try grants.get(token)
      // Reject policy/scope failures before displaying any administrator prompt.
      try preflightFileAction(r, grant: g)
      if g.elevated {
        _ = try grants.get(token)
        response = try elevatedSessions.get(token).perform(r)
      } else {
        response = try performFileAction(r, grant: g)
      }
      let audit: [String: Any] = [
        "at": Date().timeIntervalSince1970, "action": r["action"] as? String ?? "",
        "path": r["path"] as? String ?? "", "destination": r["destination"] as? String ?? "",
        "elevated": g.elevated, "ok": response["ok"] as? Bool ?? false,
      ]
      let log = dataURL.appendingPathComponent("agent-audit.jsonl")
      if !fm.fileExists(atPath: log.path) {
        fm.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600])
      }
      if let f = try? FileHandle(forWritingTo: log) {
        _ = try? f.seekToEnd()
        try? f.write(contentsOf: jsonData(audit) + Data([10]))
        try? f.close()
      }
    } catch { response = ["ok": false, "error": String(describing: error)] }
    let result = jsonData(response)
    _ = result.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, result.count) }
  }

  func agentClientProof() throws -> [String: Any] {
    guard fixture, let root = ProcessInfo.processInfo.environment["STORAGE_SAVER_FIXTURE_ROOT"]
    else { throw BrokerFailure("Fixture-only qualification") }
    func call(_ request: [String: Any], _ token: String) throws -> [String: Any] {
      let p = Process()
      p.executableURL = engine
      p.arguments = [
        "--data", dataURL.path, "--json", "agent",
        String(data: jsonData(request), encoding: .utf8)!,
      ]
      var env = ProcessInfo.processInfo.environment
      env["STORAGE_SAVER_GRANT"] = token
      p.environment = env
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardError = FileHandle.nullDevice
      try p.run()
      let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      try require(p.terminationStatus == 0, "Agent CLI did not complete")
      guard let v = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw BrokerFailure("Agent response missing")
      }
      return v
    }
    let input = URL(fileURLWithPath: root).appendingPathComponent("agent-fixture.txt").path
    try Data("agent fixture".utf8).write(to: URL(fileURLWithPath: input))
    let view = try grants.add(roots: [root], edit: false, elevated: false, ack: true)
    try require(
      try call(["action": "read", "path": input], view.token)["ok"] as? Bool == true,
      "Agent view route failed")
    try require(
      try call(["action": "write_new", "path": input + ".denied", "text": "no"], view.token)["ok"]
        as? Bool == false, "View route accepted editing")
    let edit = try grants.add(roots: [root], edit: true, elevated: false, ack: true)
    try require(
      try call(["action": "copy", "path": input, "destination": input + ".copy"], edit.token)[
        "verified"] as? Bool == true, "Agent verified-copy route failed")
    let elevated = try grants.add(roots: [root], edit: true, elevated: true, ack: true)
    let protectedReply = try call(["action": "list", "path": root + "/.hermes/workstation-control"], elevated.token)
    try require(protectedReply["ok"] as? Bool == false && (protectedReply["error"] as? String)?.contains("agent-private") == true, "Protected elevated request must fail before any administrator prompt")
    var elevatedRouteChecked = false
    if ProcessInfo.processInfo.environment["STORAGE_SAVER_TEST_ELEVATED_SESSION"] == "1" {
      let privateInput = input + ".root-only"
      let setup = Process()
      setup.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
      setup.arguments = ["-n", "/usr/bin/install", "-m", "600", input, privateInput]
      try setup.run(); setup.waitUntilExit()
      try require(setup.terminationStatus == 0 && !fm.isReadableFile(atPath: privateInput), "Native root-only fixture failed")
      var helper: Process?
      var launches = 0
      let session = try startElevatedSession(grant: elevated, executable: Bundle.main.executablePath!) { command in
        launches += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/bin/sh", "-c", "exec " + command]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); helper = p
      }
      elevatedSessions.insert(session, token: elevated.token)
      defer {
        session.close()
        helper?.waitUntilExit()
      }
      for _ in 0..<100 {
        try require(try call(["action": "read", "path": privateInput], elevated.token)["ok"] as? Bool == true,
                    "Native CLI elevated session request failed")
      }
      try require(launches == 1, "Native requests relaunched administrator helper")
      session.close()
      try require(try call(["action": "read", "path": privateInput], elevated.token)["ok"] as? Bool == false,
                  "Closed native session accepted a request")
      try require(launches == 1, "Native closed session automatically reauthenticated")
      elevatedRouteChecked = true
    }
    grants.revokeAll()
    elevatedSessions.revokeAll()
    try require(
      try call(["action": "read", "path": input], view.token)["ok"] as? Bool == false,
      "Revoked route accepted access")
    return [
      "cli_to_unix_socket": true, "view_read": true, "view_edit_denied": true,
      "copy_verified": true, "revoked_request_denied": true, "tokens_logged": false,
      "protected_elevated_path_denied_before_prompt": true,
      "elevated_cli_100_requests_one_session": elevatedRouteChecked,
    ]
  }
  func fixtureProof() {
    guard let output = ProcessInfo.processInfo.environment["STORAGE_SAVER_NATIVE_PROOF"] else {
      return
    }
    web.evaluateJavaScript(
      "JSON.stringify({title:document.title,invite:!!document.querySelector('#invite-agent'),ordinary:!!document.querySelector('#grant-ordinary'),elevated:!!document.querySelector('#grant-elevated'),rows:document.querySelectorAll('.entry').length,indexed:document.querySelector('#indexed')?.textContent})"
    ) { value, error in
      do {
        guard let text = value as? String, let data = text.data(using: .utf8),
          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BrokerFailure("Native renderer did not produce DOM proof") }
        try require(
          result["title"] as? String == "Storage Saver" && result["invite"] as? Bool == true
            && result["ordinary"] as? Bool == true && result["elevated"] as? Bool == true
            && (result["rows"] as? Int ?? 0) > 0,
          "Native app must show the actual indexed UI and access controls")
        let invitation = try self.invitation()
        try require(
          invitation.contains("CLI:") && invitation.contains("STORAGE_SAVER_GRANT"),
          "Invitation missing agent instructions")
        let brokerProof = try self.agentClientProof()
        try jsonData([
          "agent_broker": brokerProof, "passed": true, "native_window": true,
          "web_kit_rendered": result, "invitation_generated": true,
          "file_grants_default_none": self.grants.all().isEmpty, "fixture_only": true,
          "os_auth_ui_verified": false,
        ]).write(to: URL(fileURLWithPath: output))
        self.web.takeSnapshot(with: nil) { image, error in
          if let image = image, let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
          {
            try? png.write(to: URL(fileURLWithPath: output + ".png"))
          }
          NSApp.terminate(nil)
        }
      } catch {
        fputs("Native fixture failure: \(error)\n", stderr)
        NSApp.terminate(nil)
      }
    }
  }
}

if let root = arg("--session-self-test") {
  do { try sessionSelfTest(root: root, executable: Bundle.main.executablePath!); exit(0) }
  catch { fputs("Session fixture failed: \(error)\n", stderr); exit(1) }
}
if let encoded = arg("--privileged-session") {
  do { try runElevatedSession(encoded); exit(0) }
  catch { fputs("Elevated session ended: \(error)\n", stderr); exit(1) }
}
if let encoded = arg("--privileged-op") {
  DispatchQueue.global().asyncAfter(deadline: .now() + 45) { Darwin._exit(124) }
  do {
    try require(geteuid() == 0, "Administrator authorization is required")
    guard let data = Data(base64Encoded: encoded),
      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let roots = request["roots"] as? [String], let expires = request["expires"] as? Double
    else { throw BrokerFailure("Malformed scoped helper request") }
    let expiry = Date(timeIntervalSince1970: expires)
    try require(
      expiry > Date() && expiry < Date().addingTimeInterval(3601),
      "Expired or invalid helper deadline")
    let store = GrantStore()
    let checked = try store.add(
      roots: roots, edit: request["edit"] as? Bool ?? false, elevated: true, ack: true)
    var g = AgentGrant(
      token: "helper-only", roots: checked.roots, edit: checked.edit, elevated: true,
      expires: expiry)
    guard let ids = request["identities"] as? [String: [NSNumber]] else {
      throw BrokerFailure("Folder identities required")
    }
    g.identities = ids.mapValues { $0.map { $0.uint64Value } }
    print(String(data: jsonData(try performFileAction(request, grant: g)), encoding: .utf8)!)
    exit(0)
  } catch {
    print(
      String(data: jsonData(["ok": false, "error": String(describing: error)]), encoding: .utf8)!)
    exit(1)
  }
}
if let root = arg("--self-test") {
  do {
    try brokerSelfTest(root: root)
    exit(0)
  } catch {
    fputs("\(error)\n", stderr)
    exit(1)
  }
}
let app = NSApplication.shared
let delegate = Desktop()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
