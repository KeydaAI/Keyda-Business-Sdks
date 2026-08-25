Pod::Spec.new do |s|
  s.name             = 'KeydaBot'
  s.version          = '0.1.0'
  s.summary          = 'Opens the Keyda Business chat page in a WKWebView sheet over your app.'

  s.description      = <<-DESC
    A thin wrapper, not a native chat UI. KeydaBot presents a WKWebView pointed at
    https://business.keyda.in/chat/<your client id>, which is the same hosted chat that
    runs on your website, so a change made in the dashboard is live in the app with no
    App Store release. Three calls: initialize, show, dismiss. No dependencies, no
    analytics, no device identifiers.
  DESC

  s.homepage         = 'https://github.com/KeydaAI/keyda-business-sdks'
  # Resolved against the pod root, which is the repository root for a git install and
  # this directory for a `:path` install — so a copy of the licence lives in both.
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Keyda'

  # The tag is prefixed because this is a monorepo: every platform SDK in it releases
  # on its own schedule and needs its own tags.
  s.source           = { :git => 'https://github.com/KeydaAI/keyda-business-sdks.git', :tag => "ios-v#{s.version}" }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9']

  # Two patterns, because this podspec is read from two different roots. Installed
  # from the git source, CocoaPods checks out the repository and the sources are
  # under `ios/`; installed with `:path => '.../ios'`, the pod root is this directory
  # and they are not. Whichever pattern does not apply simply matches nothing, and
  # CocoaPods only complains when the attribute as a whole matches nothing.
  #
  # Do NOT collapse these into `{ios/,}Sources/...`. CocoaPods expands braces itself
  # with `set.gsub(/[{}]/, '').split(',')`, and Ruby's String#split DROPS trailing
  # empty fields — so `{ios/,}` expands to `ios/` only, the empty alternative is lost,
  # and a `:path` install silently ships a pod with no source files at all. That fails
  # as `No such module 'KeydaBot'` in the integrator's app, nowhere near the cause.
  s.source_files     = ['Sources/KeydaBot/**/*.swift', 'ios/Sources/KeydaBot/**/*.swift']

  s.frameworks       = 'UIKit', 'WebKit'
end
