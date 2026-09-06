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
/// Nearly silent. It takes what it was given, writes it where the app will find
/// it, shows a tick for a moment, and completes. The reviewing and confirming
/// all happens in the app, where it already does.
///
/// The tick is not decoration. This cannot open Wren — no share extension can
/// open its containing app, and see finish() for how thoroughly iOS means it —
/// so the share is taken and then nothing visibly happens, which is exactly
/// what failure looks like. A sheet that lingers to say "done" was rejected
/// when there was nothing else to say; there is now.
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
    guard !providers.isEmpty else { return finish(showing: false) }

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


  /// Says so, briefly, and then goes.
  ///
  /// This used to try to open Wren. It cannot, and neither can any other share
  /// extension: iOS 18 refuses both routes deliberately. Sending openURL: to
  /// whatever answers it on the responder chain — what every app that does this
  /// has historically shipped — is met with "BUG IN CLIENT OF UIKIT ... Force
  /// returning false", and NSExtensionContext.open is documented and enforced
  /// as a Today-widget call and answers false here. Apple's guidance is that an
  /// extension wanting attention should post a local notification instead.
  ///
  /// Do not try it again. Both were tried on device, in builds 164 and 165.
  ///
  /// So the problem is solved the other way round. The share worked; it simply
  /// looked as though it had not, because a sheet that vanishes in silence is
  /// what failure looks like too. A tick that lingers for a moment says the
  /// thing was taken, and the app finds it on next launch as it always has.
  ///
  /// No words, deliberately. The app is translated into forty-seven languages
  /// and this extension has no localisation of its own; a tick and the app's
  /// own name need none.
  private func confirm() {
    let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    card.layer.cornerRadius = 22
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true
    card.alpha = 0
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    let tick = UIImageView(
      image: UIImage(systemName: "checkmark.circle.fill"))
    tick.tintColor = .label
    tick.contentMode = .scaleAspectFit
    tick.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 34, weight: .regular)

    let name = UILabel()
    name.text = "Wren"
    name.textColor = .label
    name.font = .preferredFont(forTextStyle: .headline)
    name.adjustsFontForContentSizeCategory = true

    let stack = UIStackView(arrangedSubviews: [tick, name])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor,
                                 constant: 26),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor,
                                    constant: -26),
      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor,
                                     constant: 30),
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor,
                                      constant: -30),
    ])

    UIView.animate(withDuration: 0.18) { card.alpha = 1 }
  }

  /// Confirms, then completes. Completing tears the process down, so the tick
  /// has to be on screen for its own moment before that happens.
  private func finish(showing confirmation: Bool = true) {
    guard confirmation else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    confirm()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
  }
}
