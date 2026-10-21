import Darwin
import Foundation

// A private, connected channel, not an installed daemon or a general root shell.
// The helper pins one grant at launch. Requests cannot extend scope, rights or time.
func sessionAddress(_ path: String) throws -> sockaddr_un {
  try require(path.utf8.count < 104, "Private session socket path is too long")
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutablePointer(to: &address.sun_path) { p in
    p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
  }
  return address
}
func sessionPeer(_ fd: Int32, uid expectedUID: uid_t, pid expectedPID: pid_t? = nil) throws {
  var uid: uid_t = 0
  var gid: gid_t = 0
  try require(getpeereid(fd, &uid, &gid) == 0 && uid == expectedUID, "Session peer identity rejected")
  if let expectedPID {
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    try require(getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid == expectedPID,
                "Session parent process identity rejected")
  }
}
func configureSessionSocket(_ fd: Int32) {
  var timeout = timeval(tv_sec: 45, tv_usec: 0)
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var one: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}
func sessionWrite(_ fd: Int32, _ value: [String: Any]) throws {
  let bytes = jsonData(value)
  try require(bytes.count <= 131072, "Session response exceeds limit")
  var size = UInt32(bytes.count).bigEndian
  var packet = withUnsafeBytes(of: &size) { Data($0) }
  packet.append(bytes)
  try packet.withUnsafeBytes { b in
    var offset = 0
    while offset < b.count {
      let n = Darwin.write(fd, b.baseAddress!.advanced(by: offset), b.count - offset)
      if n < 0 && errno == EINTR { continue }
      try require(n > 0, "Elevated session closed; create a new grant. No automatic authentication retry.")
      offset += n
    }
  }
}
func sessionRead(_ fd: Int32) throws -> [String: Any] {
  func exact(_ size: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    var offset = 0
    while offset < size {
      let n = bytes.withUnsafeMutableBytes { b in
        Darwin.read(fd, b.baseAddress!.advanced(by: offset), size - offset)
      }
      if n < 0 && errno == EINTR { continue }
      try require(n > 0, "Elevated session ended; create a new grant. No automatic authentication retry.")
      offset += n
    }
    return Data(bytes)
  }
  let header = try exact(4)
  let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  try require(count > 0 && count <= 131072, "Invalid session frame size")
  guard let value = try JSONSerialization.jsonObject(with: exact(Int(count))) as? [String: Any]
  else { throw BrokerFailure("Invalid session response") }
  return value
}
final class ElevatedSession {
  private let lock = NSLock()
  private var fd: Int32
  let expires: Date
  init(fd: Int32, expires: Date) { self.fd = fd; self.expires = expires }
  func perform(_ request: [String: Any]) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    try require(fd >= 0 && expires > Date(), "Elevated session expired or revoked; create a new grant")
    do {
      try sessionWrite(fd, request)
      return try sessionRead(fd)
    } catch {
      // An uncertain response is never retried: the action may already have happened.
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
      fd = -1
      throw error
    }
  }
  func close() {
    lock.lock()
    defer { lock.unlock() }
    if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
  }
  deinit { close() }
}
final class ElevatedSessions {
  private let lock = NSLock()
  private var records: [String: ElevatedSession] = [:]
  func insert(_ session: ElevatedSession, token: String) {
    lock.lock(); defer { lock.unlock() }
    records[token] = session
  }
  func get(_ token: String) throws -> ElevatedSession {
    lock.lock(); defer { lock.unlock() }
    guard let session = records[token] else {
      throw BrokerFailure("Elevated session unavailable. Create a new grant once; requests never reopen authentication.")
    }
    return session
  }
  func revokeAll() {
    lock.lock(); let old = records; records.removeAll(); lock.unlock()
    for session in old.values { session.close() }
  }
  deinit { revokeAll() }
}
func startElevatedSession(grant: AgentGrant, executable: String,
                          launch: (String) throws -> Void) throws -> ElevatedSession {
  let fm = FileManager.default
  // Short private path. No persistent daemon, sudoers changes, or authorization cache.
  let directory = fm.temporaryDirectory.appendingPathComponent("ss-" + UUID().uuidString.prefix(12))
  try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                         attributes: [.posixPermissions: 0o700])
  defer { try? fm.removeItem(at: directory) }
  let path = directory.appendingPathComponent("s").path
  var address = try sessionAddress(path)
  let listener = socket(AF_UNIX, SOCK_STREAM, 0)
  try require(listener >= 0, "Could not create elevated session channel")
  defer { Darwin.close(listener) }
  configureSessionSocket(listener)
  let bound = withUnsafePointer(to: &address) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  try require(bound == 0 && chmod(path, 0o600) == 0 && listen(listener, 1) == 0,
              "Could not bind elevated session channel")
  let payload: [String: Any] = ["socket": path, "uid": getuid(), "parent": getpid(),
    "roots": grant.roots, "identities": grant.identities, "edit": grant.edit,
    "expires": grant.expires.timeIntervalSince1970]
  let command = shellQuote(executable) + " --privileged-session " + shellQuote(jsonData(payload).base64EncodedString())
  try launch(command)
  var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
  try require(poll(&ready, 1, 10000) > 0 && ready.revents & Int16(POLLIN) != 0,
              "Elevated session did not connect. No action was attempted; requests will not reprompt.")
  let fd = accept(listener, nil, nil)
  try require(fd >= 0, "Elevated session connection failed")
  do {
    configureSessionSocket(fd)
    try sessionPeer(fd, uid: 0)
    let hello = try sessionRead(fd)
    try require(hello["ok"] as? Bool == true, hello["error"] as? String ?? "Elevated session rejected")
    return ElevatedSession(fd: fd, expires: grant.expires)
  } catch { Darwin.close(fd); throw error }
}
func runElevatedSession(_ encoded: String) throws {
  try require(geteuid() == 0, "Administrator authorization is required")
  guard let data = Data(base64Encoded: encoded), data.count <= 32768,
    let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let path = input["socket"] as? String, let uid = input["uid"] as? UInt32,
    let parent = input["parent"] as? Int32, let roots = input["roots"] as? [String],
    let expiry = input["expires"] as? Double,
    let identities = input["identities"] as? [String: [NSNumber]]
  else { throw BrokerFailure("Malformed elevated session bootstrap") }
  try require(uid != 0 && parent > 1 && expiry > Date().timeIntervalSince1970
              && expiry <= Date().timeIntervalSince1970 + 3601, "Invalid elevated session lifetime")
  let checked = try GrantStore().add(roots: roots, edit: input["edit"] as? Bool ?? false,
                                      elevated: true, ack: true)
  var grant = AgentGrant(token: "channel-only", roots: checked.roots, edit: checked.edit,
                          elevated: true, expires: Date(timeIntervalSince1970: expiry))
  grant.identities = identities.mapValues { $0.map { $0.uint64Value } }
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  try require(fd >= 0, "Helper socket failed")
  defer { Darwin.close(fd) }
  configureSessionSocket(fd)
  var address = try sessionAddress(path)
  let connected = withUnsafePointer(to: &address) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  try require(connected == 0, "Grant owner no longer listening")
  try sessionPeer(fd, uid: uid, pid: parent)
  // Hard deadline also bounds a blocked filesystem operation, not just the read loop.
  DispatchQueue.global().asyncAfter(deadline: .now() + max(0, expiry - Date().timeIntervalSince1970)) {
    Darwin._exit(0)
  }
  // Disconnect, revoke and app exit all end the channel. Idle reads never prompt.
  try sessionWrite(fd, ["ok": true])
  while Date() < grant.expires {
    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let n = poll(&ready, 1, 1000)
    if n < 0 && errno == EINTR { continue }
    if n < 0 || ready.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
    if n == 0 { continue }
    let request = try sessionRead(fd)
    let response: [String: Any]
    do { response = try performFileAction(request, grant: grant) }
    catch { response = ["ok": false, "error": String(describing: error)] }
    try sessionWrite(fd, response)
  }
}
