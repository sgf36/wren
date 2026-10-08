# CocoaPods fallback only; the app builds with Swift Package Manager.
Pod::Spec.new do |s|
  s.name             = 'meta_app_events'
  s.version          = '0.1.0'
  s.summary          = "Wren's iOS-only bridge to Meta and TikTok App Events."
  s.homepage         = 'https://wren.spencerfields.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Spencer Fields' => 'apps@spencerfields.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'meta_app_events/Sources/meta_app_events/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'FBSDKCoreKit', '18.1.1'
  s.dependency 'TikTokBusinessSDK', '1.7.2'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
end
