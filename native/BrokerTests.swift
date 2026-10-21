import Darwin
import Foundation

func brokerSelfTest(root: String) throws {
  let fm = FileManager.default
  let base = URL(fileURLWithPath: root).standardizedFileURL
  try require(
    base.path != "/" && base.pathComponents.count > 3,
    "Provide a disposable, task-owned fixture folder")
  try fm.createDirectory(at: base, withIntermediateDirectories: true)
  let outside = base.appendingPathComponent("outside")
  try fm.createDirectory(at: outside, withIntermediateDirectories: true)
  var checks = [String]()
  func denied(_ body: () throws -> Void) throws {
    do {
      try body()
      throw BrokerFailure("Expected rejection was not enforced")
    } catch let e as BrokerFailure {
      if e.description == "Expected rejection was not enforced" { throw e }
    } catch {}
  }
  for elevated in [false, true] {
    for edit in [false, true] {
      let directory = base.appendingPathComponent("scope-\(elevated)-\(edit)")
      let backup = base.appendingPathComponent("backup-\(elevated)-\(edit)")
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try fm.createDirectory(at: backup, withIntermediateDirectories: true)
      let original = directory.appendingPathComponent("original.txt")
      try Data("synthetic source".utf8).write(to: original)
      let store = GrantStore()
      let g = try store.add(
        roots: [directory.path, backup.path], edit: edit, elevated: elevated, ack: true)
      let listing = try performFileAction(["action": "list", "path": directory.path], grant: g)
      try require(listing["ok"] as? Bool == true, "List failed")
      let read = try performFileAction(["action": "read", "path": original.path], grant: g)
      try require(
        Data(base64Encoded: read["data_base64"] as? String ?? "") == Data("synthetic source".utf8),
        "Read mismatch")
      try denied {
        _ = try performFileAction(
          ["action": "read", "path": outside.appendingPathComponent("not-granted").path], grant: g)
      }
      try denied {
        _ = try performFileAction(
          ["action": "read", "path": directory.path + "/../outside/not-granted"], grant: g)
      }
      try fm.createSymbolicLink(
        at: directory.appendingPathComponent("escape"), withDestinationURL: outside)
      try denied {
        _ = try performFileAction(
          ["action": "write_new", "path": directory.path + "/escape/no.txt", "text": "bad"],
          grant: g)
      }
      try denied {
        _ = try performFileAction(["action": "delete", "path": original.path], grant: g)
      }
      let expired = AgentGrant(
        token: "fixture", roots: g.roots, edit: edit, elevated: elevated,
        expires: Date().addingTimeInterval(-1))
      try denied {
        _ = try performFileAction(["action": "read", "path": original.path], grant: expired)
      }
      if edit {
        let new = directory.appendingPathComponent("new.txt").path
        _ = try performFileAction(
          ["action": "write_new", "path": new, "text": "new content"], grant: g)
        try denied {
          _ = try performFileAction(
            ["action": "write_new", "path": new, "text": "overwrite"], grant: g)
        }
        let current = try performFileAction(["action": "read", "path": new], grant: g)
        try denied {
          _ = try performFileAction(
            ["action": "replace", "path": new, "text": "bad", "expected_sha256": "wrong"], grant: g)
        }
        let replaced = try performFileAction(
          [
            "action": "replace", "path": new, "text": "revised content",
            "expected_sha256": current["sha256"]!,
          ], grant: g)
        try require(
          try String(contentsOfFile: replaced["backup_path"] as! String, encoding: .utf8)
            == "new content", "Original must survive replacement")
        try require(
          try String(contentsOfFile: new, encoding: .utf8) == "revised content",
          "Replacement readback failed")
        let copy = backup.appendingPathComponent("copy.txt").path
        let copied = try performFileAction(
          ["action": "copy", "path": original.path, "destination": copy], grant: g)
        try require(
          copied["verified"] as? Bool == true && fm.fileExists(atPath: original.path),
          "Copy must be verified and retain source")
        let moved = backup.appendingPathComponent("moved.txt").path
        _ = try performFileAction(["action": "move", "path": new, "destination": moved], grant: g)
        try require(
          !fm.fileExists(atPath: new) && fm.fileExists(atPath: moved), "Move readback failed")
        try denied {
          _ = try performFileAction(
            ["action": "move", "path": original.path, "destination": copy], grant: g)
        }
      } else {
        try denied {
          _ = try performFileAction(
            ["action": "write_new", "path": directory.path + "/denied", "text": "denied"], grant: g)
        }
      }
      let movedScope = directory.path + "-retained"
      try fm.moveItem(atPath: directory.path, toPath: movedScope)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try denied {
        _ = try performFileAction(["action": "list", "path": directory.path], grant: g)
      }
      store.revokeAll()
      try denied { _ = try store.get(g.token) }
      checks.append(
        "\(elevated ? "elevated-policy":"ordinary")-\(edit ? "edit":"view"): scope, traversal, symlink, expiry, revoke and action policy"
      )
    }
  }
  let store = GrantStore()
  try denied { _ = try store.add(roots: [base.path], edit: true, elevated: false, ack: false) }
  try denied { _ = try store.add(roots: ["/"], edit: true, elevated: true, ack: true) }
  try denied { try guardProtected(base.path + "/.ssh/key") }
  checks.append("mandatory acknowledgment; broad root and credential scope rejection")
  try denied { try guardProtected("/Users/example/.SSH/id") }
  try denied { try guardProtected("/private/var/db/example") }
  try require(
    accessPath("/System/Volumes/Data/Users/example/file") == "/Users/example/file",
    "Data-volume user aliases must normalize to the selected scope")
  let updateState = URL(fileURLWithPath: root).appendingPathComponent("update-policy")
  try fm.createDirectory(at: updateState, withIntermediateDirectories: true)
  func scanState(_ state: String, _ pid: Int32) throws {
    try jsonData(["state": state, "pid": pid]).write(to: updateState.appendingPathComponent("progress.json"))
  }
  try require(!scanBlocksApplicationTermination(updateState), "Missing scan state blocked termination")
  try scanState("scanning", getpid())
  try require(scanBlocksApplicationTermination(updateState), "Active scanner was not protected from updater termination")
  try scanState("scanning", 1)
  try require(scanBlocksApplicationTermination(updateState), "Root-owned live scanner was not protected")
  try scanState("scanning", Int32.max)
  try require(!scanBlocksApplicationTermination(updateState), "Dead stale scanner blocked termination")
  try scanState("complete", getpid())
  try require(!scanBlocksApplicationTermination(updateState), "Complete scan blocked termination")
  checks.append("updater quit gate protects live ordinary and root scans, ignores missing, complete and dead state")
  let helperDenial: NSDictionary = ["NSAppleScriptErrorNumber": 1, "NSAppleScriptErrorMessage": "{\"ok\":false,\"error\":\"Credential and agent-private paths cannot be delegated\"}"]
  let deniedReply = try decodePrivilegedReply(nil, error: helperDenial)
  try require(deniedReply["ok"] as? Bool == false && (deniedReply["error"] as? String)?.contains("agent-private") == true, "Helper policy denial must survive AppleScript nonzero exit")
  do {
    _ = try decodePrivilegedReply(nil, error: ["NSAppleScriptErrorNumber": -128])
    throw BrokerFailure("Cancellation was not rejected")
  } catch let failure as BrokerFailure {
    try require(failure.description.contains("cancelled") && !failure.description.contains("or privileged"), "Cancellation must not be confused with helper failure")
  }
  do {
    _ = try decodePrivilegedReply(nil, error: ["NSAppleScriptErrorNumber": 127])
    throw BrokerFailure("Helper launch failure was not rejected")
  } catch let failure as BrokerFailure {
    try require(failure.description.contains("127") && !failure.description.contains("cancelled"), "Launch failure must report a macOS error, not cancellation")
  }
  try denied { _ = try decodePrivilegedReply("not JSON", error: nil) }
  try denied { _ = try decodePrivilegedReply("{\"other\":true}", error: nil) }
  let syntheticCommand = "/usr/bin/printf '%s' " + shellQuote(String(data: jsonData(["ok": false, "error": "synthetic helper policy denial"]), encoding: .utf8)!) + "; exit 1"
  let syntheticSource = "do shell script \"" + syntheticCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  var scriptError: NSDictionary?
  let script = NSAppleScript(source: syntheticSource)!
  let syntheticOutput = script.executeAndReturnError(&scriptError).stringValue
  let actualReply = try decodePrivilegedReply(syntheticOutput, error: scriptError)
  try require(actualReply["ok"] as? Bool == false && actualReply["error"] as? String == "synthetic helper policy denial", "Real AppleScript must preserve failed-helper JSON")
  checks.append("real AppleScript nonzero helper output preserved without administrator prompt")
  checks.append("helper denial, explicit cancellation, launch failure and malformed reply distinguished")
  print(
    String(
      data: jsonData([
        "passed": true, "checks": checks, "disposable_fixture": true,
        "administrator_prompt_tested": false, "elevated_policy_injected_without_privilege": true,
      ]), encoding: .utf8)!)
}
