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
/// find it, opens the app, and completes — no interface of its own, because
/// there is nothing to ask and a sheet that lingers to say "done" is a sheet in
/// the way. The reviewing and confirming all happens in the app, where it
/// already does, and opening the app is what gets the user there: an extension
/// cannot show a result, and a share that arrives silently in a container reads
/// as a share that failed.
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

  /// The app's own URL scheme, registered in Runner/Info.plist. Opening it is
  /// the whole message — nothing is parsed out of it, because whatever was
  /// shared is already in the container by the time this is used. CI checks
  /// that the built app really registers this, rather than that the source
  /// says so.
  static let hostURL = "wren://shared"

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


  /// Brings Wren forward once what was shared has been written.
  ///
  /// Without this the share is accepted, written into the container, and then
  /// waits — the app drains its inbox on launch and on resume, so nothing
  /// happens until somebody thinks to open Wren themselves. From the outside
  /// that is indistinguishable from the share having failed, which is how it
  /// was reported.
  ///
  /// There is no first-class way to do this, so it tries two and settles for
  /// neither working.
  ///
  /// NSExtensionContext.open is the documented call. Apple's own documentation
  /// says only a Today extension may use it, and on current iOS it does answer
  /// for a share extension — so it is tried first, because if it works it is
  /// the supported route and needs no defending in review.
  ///
  /// Walking the responder chain to whatever answers openURL: is the fallback.
  /// It is what every app that does this has historically shipped, and iOS has
  /// been steadily less willing to allow it. The earlier attempt at this looked
  /// for a UIApplication by type; this asks whether a responder answers the
  /// selector, which is the same question asked in a way that does not depend
  /// on the chain being shaped as expected.
  ///
  /// If both fail nothing is lost. The share is already written into the
  /// container and the app collects it on next launch, exactly as it did before
  /// any of this existed.
  @discardableResult
  private func openViaResponder(_ url: URL) -> Bool {
    let selector = NSSelectorFromString("openURL:")
    var responder: UIResponder? = self
    while let current = responder {
      if current.responds(to: selector) {
        _ = current.perform(selector, with: url)
        return true
      }
      responder = current.next
    }
    return false
  }
  /// Hands over, then completes.
  ///
  /// Completing tears this process down, so it happens after the open has been
  /// attempted rather than beside it — doing both in one turn of the run loop
  /// can cancel the open. The guard exists because NSExtensionContext.open is
  /// documented for a different extension point and is not obliged to call back
  /// at all: if it stays silent the sheet must still go away, so a timer runs
  /// the fallback and finishes regardless. Whichever arrives first wins, and
  /// the other does nothing.
  private func finish() {
    guard let url = URL(string: Self.hostURL) else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }

    var settled = false
    let settle: (String) -> Void = { [weak self] how in
      guard !settled else { return }
      settled = true
      NSLog("WREN-SHARE handover: " + how)
      self?.extensionContext?.completeRequest(returningItems: nil)
    }

    extensionContext?.open(url) { [weak self] opened in
      if opened { return settle("extensionContext") }
      let viaChain = self?.openViaResponder(url) ?? false
      settle(viaChain ? "responder chain" : "nothing would open it")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard !settled else { return }
      let viaChain = self?.openViaResponder(url) ?? false
      settle(viaChain ? "responder chain, after no answer" : "no answer")
    }
  }
}
