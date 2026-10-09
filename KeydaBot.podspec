# CocoaPods packaging for the iOS SDK.
#
# Exists because the dashboard's iOS tab has always offered `pod 'KeydaBot'`
# alongside Swift Package Manager, and without this file that line was a
# promise nothing could keep. SPM is the one to publish first — it needs no
# registry and no account, only a Git tag — but a fair number of existing iOS
# apps are still CocoaPods, and telling one of them "actually, no" during
# onboarding is a bad first impression.
Pod::Spec.new do |s|
  s.name             = 'KeydaBot'
  s.version          = '0.2.0'
  s.summary          = 'Drop-in customer support chat for iOS, powered by Keyda Business.'
  s.description      = <<-DESC
    A small WebView wrapper that opens your Keyda Business bot inside your app.
    You need only the public client id from your dashboard.
  DESC
  s.homepage         = 'https://keyda.in/business'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Keyda' => 'support@keyda.in' }
  s.source           = { :git => 'https://github.com/KeydaAI/keyda-business-sdks.git',
                         :tag => "v#{s.version}" }
  # Matches Package.swift, which points its target at the same directory —
  # the two must agree or a CocoaPods consumer gets a different set of files
  # from an SPM one.
  s.source_files     = 'ios/Sources/KeydaBot/**/*.swift'
  # The privacy manifest, in a bundle of its own as Apple asks of an SDK
  # (the same file Package.swift ships).
  s.resource_bundles = { 'KeydaBot_Privacy' => ['ios/Sources/KeydaBot/PrivacyInfo.xcprivacy'] }
  s.swift_version    = '5.9'
  # 15.0 to agree with Package.swift: SPM and CocoaPods must not quote two
  # different minimums to the same integrator. Xcode 27 refuses to build a pod
  # whose deployment target is below 15.0 (13.0 was an error in `pod lib lint`
  # and in every app's Pods project).
  s.ios.deployment_target = '15.0'
  s.frameworks       = 'UIKit', 'WebKit'
end
