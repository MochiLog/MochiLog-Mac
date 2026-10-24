#!/usr/bin/env swift
import CryptoKit
import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

// Verify the CI-signed feed and archive without reading the private signing key.
// Usage: swift scripts/verify-sparkle-release.swift FEED DMG VERSION BUILD
struct VerificationError: Error, CustomStringConvertible {
  let description: String
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw VerificationError(description: message) }
}
func boundedFile(_ path: String, maximum: Int) throws -> Data {
  let url = URL(fileURLWithPath: path)
  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
  try require(size > 0 && size <= maximum, "Invalid file size: \(path)")
  return try Data(contentsOf: url, options: .mappedIfSafe)
}
final class FeedParser: NSObject, XMLParserDelegate {
  var enclosure: [String: String]?
  var version = ""
  var shortVersion = ""
  var element = ""
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    element = name
    if name == "enclosure", enclosure == nil { enclosure = attributes }
  }
  func parser(_ parser: XMLParser, foundCharacters text: String) {
    if element == "sparkle:version" { version += text }
    if element == "sparkle:shortVersionString" { shortVersion += text }
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
    qualifiedName: String?
  ) { element = "" }
}

do {
  let args = CommandLine.arguments
  try require(args.count == 5, "Expected FEED DMG VERSION BUILD")
  let raw = try boundedFile(args[1], maximum: 1_048_576)
  let marker = Data("<!-- sparkle-signatures:\n".utf8)
  guard let range = raw.range(of: marker, options: .backwards) else {
    throw VerificationError(description: "Missing signed feed trailer")
  }
  let content = raw.prefix(upTo: range.lowerBound)
  let trailer = String(decoding: raw.suffix(from: range.upperBound), as: UTF8.self)
  let lines = trailer.split(separator: "\n").map(String.init)
  try require(
    lines.count == 3 && lines[0].hasPrefix("edSignature: ")
      && lines[1] == "length: \(content.count)" && lines[2] == "-->",
    "Invalid signed feed trailer")
  let info = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil)
  guard let plist = info as? [String: Any], let encodedKey = plist["SUPublicEDKey"] as? String,
    let keyData = Data(base64Encoded: encodedKey),
    let feedSignature = Data(base64Encoded: String(lines[0].dropFirst(13)))
  else {
    throw VerificationError(description: "Invalid public key or feed signature")
  }
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
  try require(key.isValidSignature(feedSignature, for: content), "Feed signature failed")
  let delegate = FeedParser()
  let parser = XMLParser(data: Data(content))
  parser.shouldResolveExternalEntities = false
  parser.delegate = delegate
  try require(parser.parse(), "Invalid feed XML")
  try require(
    delegate.version == args[4] && delegate.shortVersion == args[3],
    "Feed version differs from the selected release")
  let expectedURL =
    "https://github.com/MochiLog/MochiLog-Mac/releases/download/v\(args[3])/MochiLog-Mac.dmg"
  guard let enclosure = delegate.enclosure,
    enclosure["url"] == expectedURL,
    let size = Int(enclosure["length"] ?? ""),
    let signature = Data(base64Encoded: enclosure["sparkle:edSignature"] ?? "")
  else {
    throw VerificationError(description: "Invalid archive enclosure")
  }
  let archive = try boundedFile(args[2], maximum: 2_000_000_000)
  try require(archive.count == size, "Archive length differs")
  try require(key.isValidSignature(signature, for: archive), "Archive signature failed")
  let result: [String: Any] = [
    "feedSignatureVerified": true, "archiveSignatureVerified": true,
    "version": delegate.shortVersion, "build": delegate.version,
    "downloadURL": expectedURL, "size": archive.count,
    "sha256": SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
  ]
  print(
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} catch {
  fputs("Release verification failed: \(error)\n", stderr)
  exit(1)
}
