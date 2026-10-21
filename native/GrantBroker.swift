import CryptoKit
import Darwin
import Foundation

struct BrokerFailure: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}
func require(_ b: Bool, _ s: String) throws { if !b { throw BrokerFailure(s) } }
func decodePrivilegedReply(_ text: String?, error: NSDictionary?) throws -> [String: Any] {
  func decode(_ value: String?) -> [String: Any]? {
    guard let value, let data = value.data(using: .utf8),
      let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      result["ok"] is Bool else { return nil }
    return result
  }
  if let error {
    let number = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
    if number == -128 {
      throw BrokerFailure("Administrator authorization was cancelled. No privileged file action was performed.")
    }
    // do shell script reports a nonzero helper exit as an AppleScript error.
    // The helper's JSON policy/filesystem failure is still authoritative, not a cancellation.
    if let result = decode(error["NSAppleScriptErrorMessage"] as? String), result["ok"] as? Bool == false {
      return result
    }
    throw BrokerFailure("Administrator authorization or helper launch failed (macOS error \(number)). This is not proof of cancellation or an expired grant. Check the app and macOS privacy permissions.")
  }
  guard let result = decode(text) else {
    throw BrokerFailure("Privileged helper returned an invalid response. No successful file action is confirmed.")
  }
  return result
}
struct AgentGrant {
  let token: String
  let roots: [String]
  let edit: Bool
  let elevated: Bool
  let expires: Date
  var identities: [String: [UInt64]] = [:]
}
final class GrantStore {
  private let lock = NSLock()
  private var records: [String: AgentGrant] = [:]
  func add(roots: [String], edit: Bool, elevated: Bool, ack: Bool, minutes: Int = 30) throws
    -> AgentGrant
  {
    try require(ack, "Risk acknowledgment is required")
    try require(!roots.isEmpty && roots.count <= 8, "Select one to eight specific folders")
    let clean = try roots.map { p -> String in
      let url = URL(fileURLWithPath: accessPath(p)).resolvingSymlinksInPath().standardizedFileURL
      let root = url.path
      try require(
        ![
          "/", "/Users", "/System", "/Library", "/private", "/Applications", "/System/Volumes/Data",
        ].contains(root), "Select specific data folders, not a whole system tree")
      for prefix in [
        "/System/", "/Library/", "/private/etc/", "/etc/", "/private/var/db/", "/usr/", "/bin/",
        "/sbin/",
      ] { try require(!root.hasPrefix(prefix), "Protected system scope cannot be delegated") }
      try require(
        !["/Volumes", "/etc", "/usr", "/bin", "/sbin"].contains(root),
        "Choose specific data folders")
      try guardProtected(root)
      var isDir: ObjCBool = false
      try require(
        FileManager.default.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue,
        "Selected folder is unavailable")
      return root
    }
    var g = AgentGrant(
      token: UUID().uuidString + UUID().uuidString, roots: clean, edit: edit, elevated: elevated,
      expires: Date().addingTimeInterval(Double(min(60, max(1, minutes))) * 60))
    for root in clean {
      var s = stat()
      try require(lstat(root, &s) == 0, "Selected folder is unavailable")
      g.identities[root] = [UInt64(s.st_dev), s.st_ino]
    }
    lock.lock()
    records[g.token] = g
    lock.unlock()
    return g
  }
  func get(_ token: String) throws -> AgentGrant {
    lock.lock()
    defer { lock.unlock() }
    guard let g = records[token], g.expires > Date() else {
      throw BrokerFailure("Missing, revoked or expired access grant")
    }
    return g
  }
  func revoke(_ token: String) {
    lock.lock()
    records.removeValue(forKey: token)
    lock.unlock()
  }
  func revokeAll() {
    lock.lock()
    records.removeAll()
    lock.unlock()
  }
  func all() -> [AgentGrant] {
    lock.lock()
    defer { lock.unlock() }
    return records.values.filter { $0.expires > Date() }.sorted { $0.expires < $1.expires }
  }
}
func accessPath(_ path: String) -> String {
  let prefix = "/System/Volumes/Data"
  if path.hasPrefix(prefix + "/Users/") || path == prefix + "/Users" {
    return String(path.dropFirst(prefix.count))
  }
  return path
}
func guardProtected(_ path: String) throws {
  let low = accessPath(path).lowercased()
  for prefix in [
    "/system", "/library", "/applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
    "/private/var/db", "/private/var/root", "/dev", "/network",
  ] {
    try require(
      low != prefix && !low.hasPrefix(prefix + "/"), "Protected system path cannot be delegated")
  }
  let parts = Set(low.split(separator: "/").map(String.init))
  let denied: Set<String> = [
    ".ssh", ".aws", ".gnupg", ".cloudflare-secrets", "keychains", "cookies", "login data", ".env",
    ".git", "credentials", "tokens.json",
    "secrets", ".hermes",
  ]
  try require(
    parts.isDisjoint(with: denied) && !parts.contains(where: { $0.hasPrefix(".env.") }),
    "Credential and agent-private paths cannot be delegated")
}
func errnoFailure() -> BrokerFailure { BrokerFailure(String(cString: strerror(errno))) }
// Descriptor-relative, no-follow traversal. A scope check followed by a path-based
// FileManager operation is not sufficient against a symlink replacement race.
func parentFD(_ rawPath: String, grant: AgentGrant) throws -> (Int32, String) {
  let path = accessPath(rawPath)
  let roots = grant.roots
  try require(
    path.hasPrefix("/") && !path.split(separator: "/").contains(".."),
    "Absolute, non-traversing path required")
  try guardProtected(path)
  guard
    let root = roots.sorted(by: { $0.count > $1.count }).first(where: {
      path == $0 || path.hasPrefix($0 + "/")
    })
  else { throw BrokerFailure("Path is outside the selected grant folders") }
  let relative = String(path.dropFirst(root.count)).split(separator: "/").map(String.init)
  var fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
  if fd < 0 { throw errnoFailure() }
  var identity = stat()
  if fstat(fd, &identity) != 0
    || grant.identities[root] != [UInt64(identity.st_dev), identity.st_ino]
  {
    Darwin.close(fd)
    throw BrokerFailure("Selected folder identity changed; revoke and reselect it")
  }
  do {
    for component in relative.dropLast() {
      let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
      if next < 0 { throw errnoFailure() }
      Darwin.close(fd)
      fd = next
    }
    return (fd, relative.last ?? ".")
  } catch {
    Darwin.close(fd)
    throw error
  }
}
func regularFD(_ parent: Int32, _ name: String) throws -> Int32 {
  let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  if fd < 0 { throw errnoFailure() }
  var st = stat()
  if fstat(fd, &st) != 0 {
    Darwin.close(fd)
    throw errnoFailure()
  }
  do {
    try require(
      (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink == 1,
      "Only regular, single-link files may be opened or changed")
    return fd
  } catch {
    Darwin.close(fd)
    throw error
  }
}
func digest(_ fd: Int32, deadline: Date) throws -> String {
  _ = lseek(fd, 0, SEEK_SET)
  var hash = SHA256()
  var buf = [UInt8](repeating: 0, count: 65536)
  while true {
    try require(Date() < deadline, "Operation time budget reached")
    let n = Darwin.read(fd, &buf, buf.count)
    if n < 0 { throw errnoFailure() }
    if n == 0 { break }
    hash.update(data: Data(buf.prefix(n)))
  }
  return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func preflightFileAction(_ request: [String: Any], grant: AgentGrant) throws {
  try require(grant.expires > Date(), "Grant expired")
  let action = request["action"] as? String ?? ""
  try require(["stat", "list", "read", "copy", "move", "write_new", "replace", "mkdir"].contains(action), "Unknown action; permanent deletion and arbitrary commands are not exposed")
  try require(!["copy", "move", "write_new", "replace", "mkdir"].contains(action) || grant.edit, "View-only grant cannot edit files")
  var paths = [request["path"] as? String ?? ""]
  if ["copy", "move"].contains(action) { paths.append(request["destination"] as? String ?? "") }
  for raw in paths {
    let path = accessPath(raw)
    try require(path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "Absolute, non-traversing path required")
    try guardProtected(path)
    try require(grant.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }), "Path is outside the selected grant folders")
  }
}
func performFileAction(_ request: [String: Any], grant: AgentGrant) throws -> [String: Any] {
  try preflightFileAction(request, grant: grant)
  let action = request["action"] as? String ?? ""
  let path = request["path"] as? String ?? ""
  let (parent, name) = try parentFD(path, grant: grant)
  defer { Darwin.close(parent) }
  let deadline = min(grant.expires, Date().addingTimeInterval(30))
  if action == "stat" {
    var st = stat()
    if fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { throw errnoFailure() }
    return [
      "ok": true, "file_bytes": st.st_size, "is_directory": (st.st_mode & S_IFMT) == S_IFDIR,
      "physical_data_bytes": NSNull(),
    ]
  }
  if action == "list" {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 { throw errnoFailure() }
    guard let dir = fdopendir(fd) else {
      Darwin.close(fd)
      throw errnoFailure()
    }
    defer { closedir(dir) }
    var names = [String]()
    while let entry = readdir(dir) {
      let value = withUnsafePointer(to: &entry.pointee.d_name) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
      }
      if value != "." && value != ".." { names.append(value) }
      if names.count >= 201 { break }
    }
    return [
      "ok": true, "entries": Array(names.sorted().prefix(200)), "has_more": names.count > 200,
      "notice": "Choose a narrower folder when truncated; filenames are private.",
    ]
  }
  if action == "mkdir" {
    try require(name != ".", "Cannot change a scope root")
    if mkdirat(parent, name, 0o700) != 0 { throw errnoFailure() }
    return ["ok": true, "created": true]
  }
  if action == "write_new" {
    guard let text = request["text"] as? String, let bytes = text.data(using: .utf8) else {
      throw BrokerFailure("Provide UTF-8 text")
    }
    try require(bytes.count <= 32768, "New text is limited to 32 KiB")
    let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if fd < 0 { throw errnoFailure() }
    defer { Darwin.close(fd) }
    try bytes.withUnsafeBytes { b in
      var pos = 0
      while pos < b.count {
        let n = Darwin.write(fd, b.baseAddress!.advanced(by: pos), b.count - pos)
        if n <= 0 { throw errnoFailure() }
        pos += n
      }
    }
    if fsync(fd) != 0 { throw errnoFailure() }
    return [
      "ok": true, "created": true, "bytes_written": bytes.count,
      "notice": "Existing files are never overwritten.",
    ]
  }
  let source = try regularFD(parent, name)
  defer { Darwin.close(source) }
  if action == "read" {
    var st = stat()
    _ = fstat(source, &st)
    try require(
      st.st_size <= 32768, "Content read is limited to 32 KiB; request metadata for larger files")
    var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
    let n = Darwin.read(source, &bytes, bytes.count)
    if n < 0 { throw errnoFailure() }
    return [
      "ok": true, "data_base64": Data(bytes.prefix(n)).base64EncodedString(), "bytes_read": n,
      "sha256": try digest(source, deadline: deadline),
    ]
  }
  if action == "replace" {
    guard let text = request["text"] as? String,
      let expected = request["expected_sha256"] as? String
    else {
      throw BrokerFailure("Replacement needs text and the expected SHA-256 from a current read")
    }
    var initial = stat()
    _ = fstat(source, &initial)
    try require(initial.st_size <= 32768, "Replacement is limited to 32 KiB text files")
    try require(
      try digest(source, deadline: deadline) == expected, "Source changed; no replacement made")
    let backupName = ".storage-saver-backup-" + UUID().uuidString
    let folder = (path as NSString).deletingLastPathComponent
    let backupPath = (folder as NSString).appendingPathComponent(backupName)
    _ = try performFileAction(
      ["action": "write_new", "path": backupPath, "text": text], grant: grant)
    if renameatx_np(parent, backupName, parent, name, UInt32(RENAME_SWAP)) != 0 {
      throw errnoFailure()
    }
    let retained = try regularFD(parent, backupName)
    defer { Darwin.close(retained) }
    var prior = stat()
    _ = fstat(retained, &prior)
    try require(
      prior.st_dev == initial.st_dev && prior.st_ino == initial.st_ino,
      "Concurrent replacement detected; inspect the retained backup before further edits")
    try require(
      try digest(retained, deadline: deadline) == expected,
      "Concurrent write detected; original path retained as backup")
    return [
      "ok": true, "replaced": true, "original_preserved": true, "backup_path": backupPath,
      "previous_sha256": expected,
      "notice": "Original retained in the same selected folder. Review before any retirement.",
    ]
  }
  let destination = request["destination"] as? String ?? ""
  let (destParent, destName) = try parentFD(destination, grant: grant)
  defer { Darwin.close(destParent) }
  try require(destName != "." && name != ".", "Cannot replace a scope root")
  if action == "move" {
    if renameatx_np(parent, name, destParent, destName, UInt32(RENAME_EXCL)) != 0 {
      throw errnoFailure()
    }
    return [
      "ok": true, "moved": true, "overwrite": false,
      "notice":
        "Atomic same-volume rename. No permanent deletion. Cross-volume moves require verified copy first.",
    ]
  }
  var st = stat()
  _ = fstat(source, &st)
  try require(
    st.st_size <= 1_073_741_824,
    "One copy is limited to 1 GiB; use an approved large-file backup tool for larger files")
  let dest = openat(destParent, destName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  if dest < 0 { throw errnoFailure() }
  defer { Darwin.close(dest) }
  var done = false
  defer {
    if !done {
      var current = stat()
      var created = stat()
      if fstat(dest, &created) == 0
        && fstatat(destParent, destName, &current, AT_SYMLINK_NOFOLLOW) == 0
        && current.st_ino == created.st_ino
      {
        _ = unlinkat(destParent, destName, 0)
      }
    }
  }
  let sourceHash = try digest(source, deadline: deadline)
  _ = lseek(source, 0, SEEK_SET)
  var buf = [UInt8](repeating: 0, count: 65536)
  while true {
    try require(Date() < deadline, "Copy time budget reached")
    let n = Darwin.read(source, &buf, buf.count)
    if n < 0 { throw errnoFailure() }
    if n == 0 { break }
    try buf.withUnsafeBytes { b in
      var pos = 0
      while pos < n {
        let m = Darwin.write(dest, b.baseAddress!.advanced(by: pos), n - pos)
        if m <= 0 { throw errnoFailure() }
        pos += m
      }
    }
  }
  if fsync(dest) != 0 { throw errnoFailure() }
  let destHash = try digest(dest, deadline: deadline)
  try require(destHash == sourceHash, "Copy verification failed; original preserved")
  var after = stat()
  _ = fstat(source, &after)
  try require(
    after.st_size == st.st_size && after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec
      && after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec, "Source changed during copy")
  done = true
  return [
    "ok": true, "copied": true, "source_preserved": true, "sha256": destHash, "verified": true,
    "overwrite": false,
  ]
}
