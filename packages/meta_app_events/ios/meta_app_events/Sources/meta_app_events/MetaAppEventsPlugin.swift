import AppTrackingTransparency
import FBSDKCoreKit
import Flutter
import StoreKit
import UIKit

/// Starts Meta's SDK, where the law allows it, and asks the tracking question.
/// Reports nothing itself.
///
/// With `FacebookAutoLogAppEventsEnabled` on (Info.plist), the SDK logs app
/// activation on every launch and App Store purchases, StoreKit 2 included, on
/// its own. Wren deliberately adds no events of its own: a hand-written
/// purchase event alongside the automatic one is how a sale gets counted
/// twice, and the SDK's own source warns against doing both.
///
/// Why the SDK is here at all, decided 4 October 2026: Meta shows an app ad to
/// iPhones on iOS 14.5+ only in an "iOS 14+" campaign, and refuses that for an
/// app that sends it no conversion data.
///
/// Why it is not started for everyone, decided the same day: in the UK and the
/// EEA, reading device details for advertising measurement needs consent first
/// (PECR regulation 6; ePrivacy Directive article 5(3)), the same rule the Wren
/// website already follows for its analytics. There the SDK is not started at
/// all until the person allows tracking. Merely switching auto-logging off is
/// not enough: starting the SDK records the install and fetches Meta's server
/// configuration regardless (ApplicationDelegate.doSDKSetup in 18.1.1).
/// Elsewhere it starts at launch, so Aggregated Event Measurement also counts
/// people who decline tracking, which is what the campaigns depend on.
public class MetaAppEventsPlugin: NSObject, FlutterPlugin {
  /// App Store storefronts (ISO 3166-1 alpha-3) where consent comes first: the
  /// United Kingdom, the 27 EU member states, Iceland, Liechtenstein and Norway.
  static let consentFirst: Set<String> = [
    "GBR",
    "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU",
    "GRC", "HUN", "IRL", "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT",
    "ROU", "SVK", "SVN", "ESP", "SWE",
    "ISL", "LIE", "NOR",
  ]

  private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  private var started = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MetaAppEventsPlugin()
    let channel = FlutterMethodChannel(
      name: "wren/meta_app_events", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Registration happens inside AppDelegate's didFinishLaunching, before it
    // calls super, so this delegate still receives didFinishLaunching below.
    registrar.addApplicationDelegate(instance)
  }

  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
  ) -> Bool {
    self.launchOptions = launchOptions as? [UIApplication.LaunchOptionsKey: Any]
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Self.firstLaunchKey) == nil {
      defaults.set(Date(), forKey: Self.firstLaunchKey)
    }
    if ATTrackingManager.trackingAuthorizationStatus == .authorized {
      start()
    } else if let country = SKPaymentQueue.default().storefront?.countryCode {
      if !Self.consentFirst.contains(country) { start() }
    } else {
      // The storefront is usually cached; when it is not, ask StoreKit 2 and
      // decide a moment later. The SDK copes with starting after launch.
      Task { @MainActor in
        if let country = await Storefront.current?.countryCode,
          !Self.consentFirst.contains(country)
        {
          self.start()
        }
      }
    }
    return true
  }

  /// Starts the SDK once. Unknown storefront counts as consent-first, so the
  /// only way to reach here without consent is a known storefront outside it.
  private func start() {
    guard !started else { return }
    started = true
    registerAttributionOnce()
    ApplicationDelegate.shared.application(
      UIApplication.shared, didFinishLaunchingWithOptions: launchOptions)
  }

  static let firstLaunchKey = "wren.attribution.firstLaunch"
  static let registeredKey = "wren.attribution.registered"
  /// Where Meta's SDK keeps its SKAdNetwork state (FBSDKSKAdNetworkReporterV2,
  /// 18.1.1). It is written only once the SDK has itself updated a value.
  static let metaReporterKey = "com.facebook.sdk:FBSDKSKAdNetworkReporter"

  /// Tells Apple, once, that Wren has launched, so an install from an ad can be
  /// attributed (SKAdNetwork, mirrored into AdAttributionKit by the system).
  ///
  /// Why Wren does this itself, decided 4 Oct 2026: Apple requires the
  /// advertised app to update a conversion value at first launch, and Meta's
  /// SDK does so only from a configuration Meta serves, which was empty for
  /// Wren ({"data": []}). With no configuration no install could be attributed.
  ///
  /// Why it cannot fight the SDK: it runs at most once, before the SDK starts,
  /// with the lowest values (fine 0, coarse low), and not at all if the SDK has
  /// already updated anything; Meta's later rules only raise it. Meta asks for
  /// no updates beyond 24 hours after install, so it is skipped after that.
  ///
  /// Why it sits behind the same consent gate as the SDK (called from start()):
  /// the postback it enables goes to Meta, and in UK/EEA storefronts the
  /// privacy policy promises nothing reaches Meta until tracking is allowed.
  private func registerAttributionOnce() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.registeredKey),
      defaults.object(forKey: Self.metaReporterKey) == nil
    else { return }
    let first = defaults.object(forKey: Self.firstLaunchKey) as? Date ?? Date()
    guard Date().timeIntervalSince(first) < 24 * 60 * 60 else { return }
    defaults.set(true, forKey: Self.registeredKey)
    if #available(iOS 16.1, *) {
      SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low, lockWindow: false) { _ in }
    } else if #available(iOS 15.4, *) {
      SKAdNetwork.updatePostbackConversionValue(0) { _ in }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "trackingUndetermined":
      result(ATTrackingManager.trackingAuthorizationStatus == .notDetermined)
    case "requestTracking":
      // Apple shows this once per install; asking again returns the stored
      // answer without a dialog. Only meaningful while the app is active,
      // which is why Dart calls it on resume.
      guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
        result(false)
        return
      }
      ATTrackingManager.requestTrackingAuthorization { status in
        DispatchQueue.main.async {
          if status == .authorized { self.start() }
          result(true)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
