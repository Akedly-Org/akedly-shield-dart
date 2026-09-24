Pod::Spec.new do |s|
  s.name             = 'akedly_shield'
  s.version          = '1.2.0'
  s.summary          = 'Akedly Shield Flutter SDK'
  s.description      = 'PoW, Turnstile, hosted passkey, and native passkey helpers for Akedly Shield.'
  s.homepage         = 'https://github.com/Akedly-Org/akedly-shield-dart'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Akedly' => 'developers@akedly.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
