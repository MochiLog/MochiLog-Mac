import CryptoKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let resource = folder.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
let plist = try PropertyListSerialization.data(
  fromPropertyList: ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()],
  format: .xml, options: 0)
try plist.write(to: resource.appendingPathComponent("Info.plist"))
let archive = Data("synthetic archive fixture".utf8)
try archive.write(to: folder.appendingPathComponent("archive.dmg"))
try Data("Synthetic archive fixture".utf8).write(to: folder.appendingPathComponent("tampered.dmg"))
let signature = try key.signature(for: archive).base64EncodedString()
func item(_ version: String, _ build: String, wrongURL: Bool = false) -> String {
  let path = wrongURL ? "wrong-file.dmg" : "MochiLog-Mac.dmg"
  return """
  <item><sparkle:version>\(build)</sparkle:version>
  <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
  <enclosure url="https://github.com/MochiLog/MochiLog-Mac/releases/download/v\(version)/\(path)" length="\(archive.count)" sparkle:edSignature="\(signature)" /></item>
  """
}
func write(_ name: String, _ body: String) throws {
  let text = "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>" + body + "</channel></rss>\n"
  let bytes = Data(text.utf8)
  let sig = try key.signature(for: bytes).base64EncodedString()
  let trailer = "<!-- sparkle-signatures:\nedSignature: \(sig)\nlength: \(bytes.count)\n-->\n"
  try Data((text + trailer).utf8).write(to: folder.appendingPathComponent(name))
}
try write("valid.xml", item("1.0.3", "41") + item("1.0.2", "40"))
try write("old-first.xml", item("1.0.2", "40") + item("1.0.3", "41"))
try write("wrong-url.xml", item("1.0.3", "41", wrongURL: true))
let valid = try String(contentsOf: folder.appendingPathComponent("valid.xml"), encoding: .utf8)
try Data(valid.replacingOccurrences(of: ">41<", with: ">42<").utf8)
  .write(to: folder.appendingPathComponent("tampered.xml"))
