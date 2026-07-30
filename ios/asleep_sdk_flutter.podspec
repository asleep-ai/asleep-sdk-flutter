#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint asleep_sdk_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'asleep_sdk_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Experimental Flutter plugin for the Asleep sleep tracking SDK.'
  s.description      = <<-DESC
Typed lifecycle, event, permission, analysis, and report access for Android and iOS.
                       DESC
  s.homepage         = 'https://www.asleep.ai'
  s.license          = {
    :type => 'Proprietary',
    :file => '../LICENSE'
  }
  s.author           = { 'Asleep' => 'platform-cs@asleep.ai' }
  s.source           = { :path => '.' }
  s.source_files = 'asleep_sdk_flutter/Sources/asleep_sdk_flutter/**/*.{h,m,swift}'
  s.dependency 'Flutter'
  s.dependency 'AsleepSDK', '3.2.0'
  s.platform = :ios, '15.0'
  s.static_framework = true

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

end
