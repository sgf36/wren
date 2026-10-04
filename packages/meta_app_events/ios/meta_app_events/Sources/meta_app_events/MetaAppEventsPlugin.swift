import AppTrackingTransparency
import FBSDKCoreKit
import Flutter
import UIKit

/// Starts Meta's SDK and asks the tracking question. Reports nothing itself.
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
public class MetaAppEventsPlugin: NSObject, FlutterPlugin {
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
    ApplicationDelegate.shared.application(
      application,
      didFinishLaunchingWithOptions: launchOptions as? [UIApplication.LaunchOptionsKey: Any])
    return true
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
      ATTrackingManager.requestTrackingAuthorization { _ in
        DispatchQueue.main.async { result(true) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
