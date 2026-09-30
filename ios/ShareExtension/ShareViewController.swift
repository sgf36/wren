import MobileCoreServices
import Social
import UIKit
import UniformTypeIdentifiers
import UserNotifications

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

  /// The confirmation card's stack, kept so its buttons can be replaced when
  /// opening Wren turns out not to be possible. Held weakly: the view owns it,
  /// and a strong reference here would outlive the card it describes.
  private weak var confirmationStack: UIStackView?

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


  /// Shows what happened and offers to open Wren.
  ///
  /// The card stays until the user taps "Open Wren" or dismisses. Replacing
  /// the old 0.9-second auto-dismiss, because a sheet that vanishes in silence
  /// tells the user nothing — especially when iOS prevents a share extension
  /// from opening its own app automatically.
  ///
  /// "Open Wren" is handled by `openApp`, which tries two routes and, if both
  /// fail, replaces these buttons with an instruction rather than closing.
  ///
  /// It used to close regardless, which made a failed open and a successful
  /// one identical from the outside — the card vanished, Instagram came back,
  /// and "Open Wren" behaved exactly like "Done". An earlier note here claimed
  /// later iOS point releases had relaxed the restriction on
  /// `extensionContext.open` for a registered scheme owned by the same team.
  /// On a device running iOS 26 it still returns false, so that claim is
  /// removed rather than left to mislead the next person.
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
    tick.tintColor = .systemGreen
    tick.contentMode = .scaleAspectFit
    tick.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 34, weight: .regular)

    let name = UILabel()
    name.text = "Wren"
    name.textColor = .label
    name.font = .preferredFont(forTextStyle: .headline)
    name.adjustsFontForContentSizeCategory = true

    let openButton = UIButton(type: .system)
    openButton.setTitle("Open Wren", for: .normal)
    openButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
    openButton.titleLabel?.adjustsFontForContentSizeCategory = true
    openButton.backgroundColor = .label
    openButton.setTitleColor(.systemBackground, for: .normal)
    openButton.layer.cornerRadius = 14
    openButton.layer.cornerCurve = .continuous
    openButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 28, bottom: 10, right: 28)
    openButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)

    let doneButton = UIButton(type: .system)
    doneButton.setTitle("Done", for: .normal)
    doneButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
    doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
    doneButton.setTitleColor(.secondaryLabel, for: .normal)
    doneButton.addTarget(self, action: #selector(dismissExtension), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [tick, name, openButton, doneButton])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    stack.setCustomSpacing(16, after: name)
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(stack)
    confirmationStack = stack

    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor,
                                 constant: 26),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor,
                                    constant: -20),
      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor,
                                     constant: 30),
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor,
                                      constant: -30),
    ])

    UIView.animate(withDuration: 0.18) { card.alpha = 1 }
  }

  /// Opens Wren, or says plainly that it could not.
  ///
  /// The previous version discarded the `success` flag and completed the
  /// extension either way, so a failed open and a successful one did exactly
  /// the same visible thing: the card vanished and you were back in Instagram.
  /// "Open Wren" and "Done" were the same button. That is what "it doesn't do
  /// anything" looked like from the outside, and it hid the real problem for a
  /// week.
  ///
  /// Two routes are tried, because `extensionContext.open` is documented for a
  /// subset of extension points that has never reliably included share
  /// extensions -- it returns false, silently, on the device this was tested
  /// on. The responder-chain route is the long-standing way round it: walk up
  /// to the UIApplication and ask it directly. `openURL:` is public API; it is
  /// sent with `perform` because the Swift method carries an
  /// `iOSApplicationExtension, unavailable` annotation that would otherwise
  /// refuse to compile here.
  ///
  /// **Both routes are raced against a one-second deadline.** Observed on a
  /// device: tapping the button produced no visible change at all -- not even
  /// the fallback text below, which only runs inside `open`'s completion
  /// handler. That handler is not documented to fire for a share extension,
  /// and evidently does not always. Waiting on it unconditionally is how a
  /// silent non-callback becomes a button that does nothing; the deadline
  /// guarantees the card says something within a second either way. A `resolved`
  /// flag, checked and set only on the main queue, stops both routes from
  /// firing once the card has already moved on.
  @objc private func openApp() {
    guard let url = URL(string: "wren://shared") else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }

    var resolved = false
    let decide: (Bool) -> Void = { [weak self] success in
      DispatchQueue.main.async {
        guard let self, !resolved else { return }
        resolved = true
        if success || self.openViaResponderChain(url) {
          self.extensionContext?.completeRequest(returningItems: nil)
          return
        }
        // Neither route worked, or neither answered in time. The share is
        // already in the App Group container, so nothing is lost -- but saying
        // nothing and closing is what made this look broken, so the card says
        // what to do instead.
        self.explainCouldNotOpen()
      }
    }

    extensionContext?.open(url) { success in decide(success) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { decide(false) }
  }

  /// Asks the UIApplication to open a URL, from inside an extension.
  ///
  /// Returns whether anything was found to ask. It cannot report what the app
  /// then did, because `openURL:` predates completion handlers -- so a true
  /// here means "handed over", not "Wren is on screen".
  private func openViaResponderChain(_ url: URL) -> Bool {
    // Matched on the type rather than on `responds(to:)`. Several things in a
    // responder chain will answer to a selector named `openURL:` and mean
    // something else by it; only UIApplication means this.
    let selector = NSSelectorFromString("openURL:")
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication,
         application.responds(to: selector) {
        application.perform(selector, with: url)
        return true
      }
      responder = current.next
    }
    return false
  }

  /// Replaces the card's buttons with an instruction that actually works.
  private func explainCouldNotOpen() {
    guard let stack = confirmationStack else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    for view in stack.arrangedSubviews where view is UIButton {
      view.removeFromSuperview()
    }

    let advice = UILabel()
    advice.text = "Saved. Open Wren from the Home Screen to finish."
    advice.textColor = .secondaryLabel
    advice.font = .preferredFont(forTextStyle: .subheadline)
    advice.adjustsFontForContentSizeCategory = true
    advice.numberOfLines = 0
    advice.textAlignment = .center

    let close = UIButton(type: .system)
    close.setTitle("Done", for: .normal)
    close.titleLabel?.font = .preferredFont(forTextStyle: .body)
    close.titleLabel?.adjustsFontForContentSizeCategory = true
    close.setTitleColor(.secondaryLabel, for: .normal)
    close.addTarget(self, action: #selector(dismissExtension),
                    for: .touchUpInside)

    stack.addArrangedSubview(advice)
    stack.addArrangedSubview(close)
    advice.widthAnchor.constraint(
      lessThanOrEqualToConstant: 240).isActive = true
  }

  @objc private func dismissExtension() {
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// Schedules a local notification so the user can tap it to open Wren.
  ///
  /// Share extensions cannot open their containing app — `extensionContext.open`
  /// returns false, and the responder-chain workaround broke in iOS 18. A local
  /// notification is Apple's documented alternative: the extension schedules one,
  /// the user taps it, iOS opens the app, and the existing App Group pickup in
  /// `_takeSharedGuide` handles the rest.
  ///
  /// The notification fires after one second rather than immediately, so it
  /// arrives after the share sheet has dismissed — a notification while the sheet
  /// is still up is swallowed by the host app.
  ///
  /// The main app also requests permission on launch, but that is not enough on
  /// its own: somebody who installs or updates Wren and only ever uses it by
  /// sharing into it — never opening it from the Home Screen — will have shared
  /// before the main app's `didFinishLaunchingWithOptions` ever runs, so nothing
  /// will have asked yet. Requesting again here, from the extension itself,
  /// closes that gap; `.provisional` does not prompt on a repeat call, so asking
  /// twice costs nothing. If the user has notifications off entirely, this
  /// still silently does nothing and the fallback message in
  /// `explainCouldNotOpen` still tells them to open from the Home Screen.
  private func scheduleOpenNotification() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .provisional]) { _, error in
      if let error = error {
        NSLog("WREN-SHARE notification permission failed: \(error.localizedDescription)")
      }

      let content = UNMutableNotificationContent()
      content.title = "Wren"
      content.body = "Tap to finish importing."
      content.sound = .none

      let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
      let request = UNNotificationRequest(
        identifier: "com.spencerfields.littlebird.share-open",
        content: content,
        trigger: trigger)

      center.add(request) { error in
        if let error = error {
          NSLog("WREN-SHARE notification failed: \(error.localizedDescription)")
        }
      }
    }
  }

  /// Confirms, then waits for the user. If no confirmation is needed, tears
  /// down immediately.
  private func finish(showing confirmation: Bool = true) {
    scheduleOpenNotification()
    guard confirmation else {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    confirm()
  }
}
