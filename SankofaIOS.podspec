Pod::Spec.new do |s|
  s.name             = 'SankofaIOS'
  s.version          = '1.0.0'
  s.summary          = 'Sankofa iOS SDK — event tracking, session replay, heatmaps.'
  s.homepage         = 'https://sankofa.dev'
  s.license          = { type: 'MIT' }
  s.authors          = { 'Sankofa Team' => 'hello@sankofa.dev' }
  s.source           = { git: 'https://github.com/Sankofa-HQ/sankofa_sdk_ios.git', tag: "v#{s.version}" }
  s.swift_version    = '5.9'
  s.ios.deployment_target = '14.0'

  s.source_files = 'Sources/SankofaIOS/**/*.{swift}'

  # PrivacyInfo manifest (required for App Store submissions)
  s.resource_bundles = {
    'SankofaIOS_Privacy' => ['Sources/SankofaIOS/PrivacyInfo.xcprivacy']
  }

  # GRDB.swift — SQLite-backed offline event queue.
  # Pinned to the exact version used by the SPM Package.swift definition.
  s.dependency 'GRDB.swift', '= 7.10.0'

  # libz — used by Data+Gzip.swift for GZIP compression of replay chunks.
  s.library = 'z'

  s.frameworks = ['UIKit', 'Foundation', 'CoreGraphics', 'QuartzCore']
end
