import Foundation

/// An endpoint hint is not identity proof. Direct connections must still
/// authenticate with the existing OS pairing record for the selected UDID.
enum DiagnosticRoutes {
  struct Candidate: Equatable {
    let address: String
    let source: String
  }
  struct Report: Codable {
    struct Endpoint: Codable { let address, source: String }
    var manual: String?
    let peer: String?
    let peerAt: String?
    var hints: [String]
    let hintsAt: String?
    let verified: String?
    let verifiedAt: String?
    var candidates: [Endpoint]
    var isBounded: Bool {
      [manual, peer, verified].allSatisfy({ ($0?.count ?? 0) <= 64 })
        && [peerAt, hintsAt, verifiedAt].allSatisfy({ ($0?.count ?? 0) <= 64 })
        && hints.count <= 4 && hints.allSatisfy({ $0.count <= 64 })
        && candidates.count <= 8 && candidates.allSatisfy({ $0.address.count <= 64 && $0.source.count <= 96 })
    }
  }
  private struct Cache: Codable {
    var version = 1
    var hints: [String] = []
    var hintsAt: Date?
    var verified: String?
    var verifiedAt: Date?
    var peer: String?
    var peerAt: Date?
  }
  private static let lock = NSLock()

  static func privateLANAddress(_ text: String) -> String? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    let bytes = parts.compactMap { UInt8($0) }
    guard bytes.count == 4, zip(parts, bytes).allSatisfy({ String($0.1) == $0.0 }),
      bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
        (bytes[0] == 192 && bytes[1] == 168) else { return nil }
    return bytes.map(String.init).joined(separator: ".")
  }
  private static func file(_ id: UUID) -> URL {
    Collector.root.appendingPathComponent("DiagnosticRoutes", isDirectory: true)
      .appendingPathComponent(id.uuidString + ".json")
  }
  private static func load(_ id: UUID) -> Cache {
    guard let bytes = BoundedDiagnosticFile.read(file(id), maximum: 8192),
      let cache = try? JSONDecoder().decode(Cache.self, from: bytes), cache.version == 1
    else { return Cache() }
    return cache
  }
  static func describe(_ device: PairedDevice) -> Report {
    lock.lock(); let cache = load(device.physicalDeviceID); lock.unlock()
    let time: (Date?) -> String? = { $0.map(SupportDiagnostics.localTime) }
    return Report(manual: device.manualAddress.map { String($0.prefix(64)) },
      peer: cache.peer.flatMap(privateLANAddress), peerAt: time(cache.peerAt),
      hints: cache.hints.prefix(4).compactMap(privateLANAddress), hintsAt: time(cache.hintsAt),
      verified: cache.verified.flatMap(privateLANAddress), verifiedAt: time(cache.verifiedAt),
      candidates: candidates(for: device).prefix(8).map { Report.Endpoint(address: $0.address, source: $0.source) })
  }
  private static func save(_ cache: Cache, id: UUID) {
    do {
      let path = file(id)
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(cache).write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    } catch {
      SupportDiagnostics.record("Diagnostic route cache save failed; device=\(id); error=\(error.localizedDescription)")
    }
  }
  @discardableResult
  static func receiveHints(_ encoded: String, for id: UUID, at now: Date = Date()) -> Bool {
    guard encoded.utf8.count <= 512, let data = encoded.data(using: .utf8),
      let supplied = try? JSONDecoder().decode([String].self, from: data), supplied.count <= 4,
      supplied.allSatisfy({ privateLANAddress($0) != nil }) else { return false }
    var seen = Set<String>()
    let hints = supplied.filter { seen.insert($0).inserted }
    lock.lock(); defer { lock.unlock() }
    var cache = load(id)
    let changed = cache.hints != hints
    guard changed || cache.hintsAt.map({ now.timeIntervalSince($0) >= 300 }) != false else { return false }
    cache.hints = hints; cache.hintsAt = now; save(cache, id: id)
    if changed {
      SupportDiagnostics.record("Diagnostic route hints updated; device=\(id); count=\(hints.count); source=sealed v3 request; verified=false; received=\(SupportDiagnostics.localTime(now))")
    }
    return changed
  }
  static func rememberPeer(_ address: String?, for id: UUID, at now: Date = Date()) {
    guard let address, let canonical = privateLANAddress(address) else { return }
    lock.lock(); defer { lock.unlock() }
    var cache = load(id)
    guard cache.peer != canonical || cache.peerAt.map({ now.timeIntervalSince($0) >= 300 }) != false else { return }
    cache.peer = canonical; cache.peerAt = now; save(cache, id: id)
  }
  static func rememberVerified(_ address: String, for id: UUID, at now: Date = Date()) {
    guard let address = privateLANAddress(address) else { return }
    lock.lock(); defer { lock.unlock() }
    var cache = load(id)
    guard cache.verified != address || cache.verifiedAt.map({ now.timeIntervalSince($0) >= 300 }) != false else { return }
    cache.verified = address; cache.verifiedAt = now; save(cache, id: id)
    SupportDiagnostics.record("Diagnostic route authenticated; device=\(id); address=\(address); verified=OS pairing; at=\(SupportDiagnostics.localTime(now))")
  }
  static func candidates(for device: PairedDevice, at now: Date = Date()) -> [Candidate] {
    if let address = device.manualAddress { return [Candidate(address: address, source: "manual")] }
    lock.lock(); defer { lock.unlock() }
    let cache = load(device.physicalDeviceID)
    func fresh(_ date: Date?, seconds: Double) -> Bool {
      guard let date else { return false }
      return (0...seconds).contains(now.timeIntervalSince(date))
    }
    var result: [Candidate] = []
    if fresh(cache.hintsAt, seconds: 3600) {
      result += cache.hints.compactMap { privateLANAddress($0).map {
        Candidate(address: $0, source: "authenticated mobile LAN hint (unverified)")
      } }
    }
    if fresh(cache.verifiedAt, seconds: 7 * 86400), let value = cache.verified,
      let address = privateLANAddress(value) {
      result.append(Candidate(address: address, source: "previous OS-authenticated endpoint"))
    }
    // Daily receipt pauses can suppress mobile requests for many hours. Keep
    // recent authenticated hints as a fallback after the verified endpoint.
    if !fresh(cache.hintsAt, seconds: 3600), fresh(cache.hintsAt, seconds: 86400) {
      result += cache.hints.compactMap { privateLANAddress($0).map {
        Candidate(address: $0, source: "recent authenticated mobile LAN hint (unverified)")
      } }
    }
    if fresh(cache.peerAt, seconds: 86400), let value = cache.peer,
      let address = privateLANAddress(value) {
      result.append(Candidate(address: address, source: "transfer peer fallback (unverified)"))
    }
    var seen = Set<String>()
    return result.filter { seen.insert($0.address).inserted }
  }
}
