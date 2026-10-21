import Darwin
import Foundation

// Explicit CLI-only opt-in. Synthetic files only, never the live index or grants.
func sessionSelfTest(root: String, executable: String) throws {
  let fm = FileManager.default
  try fm.createDirectory(atPath: root, withIntermediateDirectories: false)
  let seed = root + "/seed"
  let restricted = root + "/root-only"
  try Data("synthetic root-only session fixture".utf8).write(to: URL(fileURLWithPath: seed))
  func run(_ command: String, _ args: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: command); p.arguments = args
    try p.run(); p.waitUntilExit()
    try require(p.terminationStatus == 0, "Fixture setup failed")
  }
  try run("/usr/bin/sudo", ["-n", "/usr/bin/install", "-m", "600", seed, restricted])
  try require(!fm.isReadableFile(atPath: restricted), "Fixture must actually require root")
  let store = GrantStore()
  var children = [Process]()
  var launches = 0
  var sessions = [ElevatedSession]()
  defer {
    for session in sessions { session.close() }
    for p in children {
      let until = Date().addingTimeInterval(5)
      while p.isRunning && Date() < until { usleep(10000) }
      if p.isRunning { p.terminate() }
      p.waitUntilExit()
    }
  }
  func start(_ g: AgentGrant) throws -> ElevatedSession {
    let s = try startElevatedSession(grant: g, executable: executable) { command in
      launches += 1
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
      p.arguments = ["-n", "/bin/sh", "-c", "exec " + command]
      p.standardOutput = FileHandle.nullDevice
      try p.run(); children.append(p)
    }
    sessions.append(s)
    return s
  }
  let view = try store.add(roots: [root], edit: false, elevated: true, ack: true)
  let session = try start(view)
  for _ in 0..<100 {
    let result = try session.perform(["action": "read", "path": restricted])
    try require(result["ok"] as? Bool == true && result["data_base64"] as? String == Data("synthetic root-only session fixture".utf8).base64EncodedString(),
                "Root-only read failed during repeated requests")
  }
  try require(launches == 1, "Repeated actions relaunched authentication")
  let denied = try session.perform(["action": "write_new", "path": root + "/denied", "text": "no",
                                   "edit": true, "roots": ["/"], "expires": Date().addingTimeInterval(99999).timeIntervalSince1970])
  try require(denied["ok"] as? Bool == false, "Request escalated pinned view grant")
  for request: [String: Any] in [
    ["action": "delete", "path": restricted],
    ["action": "read", "path": root + "/../outside"],
    ["action": "list", "path": root + "/.hermes"],
    ["action": "read", "path": "/etc/passwd"]
  ] {
    try require(try session.perform(request)["ok"] as? Bool == false, "Unsafe action accepted")
  }
  try require(launches == 1, "Denied actions prompted again")
  session.close()
  do { _ = try session.perform(["action": "read", "path": restricted]); throw BrokerFailure("Revoked transport accepted") }
  catch let error as BrokerFailure { try require(error.description != "Revoked transport accepted", "Revoked transport accepted") }
  try require(launches == 1, "Closed session attempted automatic authentication retry")
  let edit = try store.add(roots: [root], edit: true, elevated: true, ack: true)
  let editSession = try start(edit)
  let copy = try editSession.perform(["action": "copy", "path": restricted, "destination": root + "/copied"])
  try require(copy["verified"] as? Bool == true, "Session verified copy failed")
  let short = AgentGrant(token: "short", roots: edit.roots, edit: false, elevated: true,
                          expires: Date().addingTimeInterval(2), identities: edit.identities)
  let expiring = try start(short)
  Thread.sleep(forTimeInterval: 2.2)
  do { _ = try expiring.perform(["action": "read", "path": restricted]); throw BrokerFailure("Expired session accepted") }
  catch let error as BrokerFailure { try require(error.description != "Expired session accepted", "Expired session accepted") }
  expiring.close()
  let disconnectedChild = children[0]
  let deadline = Date().addingTimeInterval(3)
  while disconnectedChild.isRunning && Date() < deadline { usleep(10000) }
  try require(!disconnectedChild.isRunning, "Helper survived revoked channel")
  print(String(data: jsonData(["passed": true, "requests_in_one_session": 100,
    "helper_launches_for_100_requests": 1, "root_only_reads_verified": true,
    "view_escalation_denied": true, "protected_scope_denied": true,
    "delete_denied": true, "copy_verified": true, "closed_session_no_reprompt": true,
    "expiry_denied": true, "helper_exits_on_disconnect": true,
    "native_password_ui_tested": false, "synthetic_files_only": true]), encoding: .utf8)!)
}
