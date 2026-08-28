import MobileCoreServices
import Social
import UIKit
import UniformTypeIdentifiers

/// Wren in the iOS share sheet.
///
/// Everything in that sheet's app row is an app shipping a share extension, which
/// is the only way in: an app cannot volunteer itself for sharing any other way.
///
/// Two things arrive here. Apple Maps shares a guide as a `maps.apple/ug/…` short
/// link, and Wren already expands and decodes exactly that. And screenshots —
/// the reason the app exists. Somebody sends a reel, you screenshot it, and this
/// replaces screenshot → leave the app → open Wren → Add → picker → choose with
/// share → Wren.
///
/// Deliberately silent. It takes what it was given, writes it where the app will
/// find it, and completes — no interface of its own, because there is nothing to
/// ask and a sheet that lingers to say "done" is a sheet in the way. The
/// reviewing and confirming all happens in the app, where it already does.
///
/// Apple Maps only, for links. A shared Google Maps list URL is opaque — no
/// documented format, nothing to decode — so `Info.plist` does not claim it, and
/// Wren does not appear in Google's share sheet promising something it cannot do.
class ShareViewController: UIViewController {
  /// Shared with the app through the App Group container. App Groups cannot be
  /// created through the App Store Connect API — it answers 404 for the resource
  /// — so this identifier must exist in the developer portal and be enabled on
  /// both this extension's App ID and the app's.
  static let appGroup = "group.com.spencerfields.littlebird"

  /// The app reads and deletes this on launch and on resume. A file rather than
  /// UserDefaults: a share arriving while the app is already open has to be
  /// noticed, and a file's presence is unambiguous.
  static let handoffName = "shared-guide-link.txt"

  /// Screenshots land in their own directory beside the link, and the app empties
  /// it as it collects. A directory rather than a manifest file, so there is one
  /// source of truth about what is waiting: a manifest can disagree with the
  /// files it lists, a directory listing cannot.
  static let inboxName = "shared-images"

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    guard !providers.isEmpty else { return finish() }

    // Every provider is handled, and finish() waits for all of them. Completing
    // the request tears this process down, so returning after the first would
    // leave the rest of a multi-image share unwritten — and the sheet would look
    // exactly as successful as a complete one.
    let group = DispatchGroup()
    var imageIndex = 0

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
          if let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) {
            self?.hand(over: url)
          }
          group.leave()
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        let index = imageIndex
        imageIndex += 1
        group.enter()
        // loadFileRepresentation gives a file on disk that is deleted the moment
        // the closure returns, so it is copied synchronously inside it. An async
        // hop here loses the file, and loses it silently.
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
          [weak self] url, _ in
          if let url = url { self?.copy(image: url, index: index) }
          group.leave()
        }
      }
    }

    group.notify(queue: .main) { [weak self] in self?.finish() }
  }

  /// The App Group container, or nil with a note in the log.
  ///
  /// No App Group means no channel to the app. Failing quietly is right: the
  /// paste and picker routes both still work, and an alert here would be a dead
  /// end in a sheet the user is trying to dismiss.
  private func container() -> URL? {
    let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroup)
    if url == nil { NSLog("WREN-SHARE no container for \(Self.appGroup)") }
    return url
  }

  private func hand(over url: URL) {
    guard let container = container() else { return }
    let target = container.appendingPathComponent(Self.handoffName)
    do {
      try url.absoluteString.write(to: target, atomically: true, encoding: .utf8)
    } catch {
      NSLog("WREN-SHARE could not write handoff: \(error.localizedDescription)")
    }
  }

  private func copy(image source: URL, index: Int) {
    guard let container = container() else { return }
    let inbox = container.appendingPathComponent(Self.inboxName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: inbox,
                                              withIntermediateDirectories: true)
      // Named by position and by when it arrived, because a share sheet hands
      // over several files that can all be called IMG_0001.PNG and a collision
      // would drop one of them without saying so.
      let stamp = Int(Date().timeIntervalSince1970 * 1000)
      let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
      let target = inbox.appendingPathComponent("\(stamp)-\(index).\(ext)")
      try FileManager.default.copyItem(at: source, to: target)
    } catch {
      NSLog("WREN-SHARE could not copy image: \(error.localizedDescription)")
    }
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
