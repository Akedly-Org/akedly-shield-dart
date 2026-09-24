# Changelog

## 1.2.0

- Add native iOS and Android passkey registration and authentication through an Akedly-owned Flutter method channel.
- Preserve the hosted `flutter_web_auth_2` ceremony and the existing Dart API.
- Upgrade `flutter_web_auth_2` to `4.1.0` because the older Android Registrar integration cannot build with current Flutter tooling. Its `web` dependency makes Dart 3.3 and Flutter 3.22.3 the smallest maintained compatible floors, so this is a breaking public floor rise; native behavior is unchanged.
- Add the public native failure taxonomy, platform setup guidance, and pub.dev package metadata.
- Android hosts must use `minSdk` 24 or newer, `compileSdk` 35 or newer, AGP 8.6 or newer, JDK 17, and a Kotlin 2.x-capable Gradle plugin for the Credential Manager 1.6.0 bridge. The `minSdk` requirement is a breaking change for host apps supporting Android API 21–23, including hosted-only consumers.
- Set the iOS plugin deployment target to 12.0; native passkeys require iOS 16 and Xcode 15.3 or newer.
- Provenance: ported from swift@2cce2ab8, kotlin@552dd3c2.
