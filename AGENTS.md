# AGENTS.md — akedly-shield-dart

Flutter/Dart client SDK for Akedly's **V1.2 secure REST API**. Three independent pieces under
`lib/src/`, re-exported from `lib/akedly_shield.dart`:

| File | What it does |
|---|---|
| `solver.dart` | Proof-of-work solver — finds a nonce whose `sha256(challenge + ":" + nonce)` has N leading zeros |
| `turnstile.dart` | Cloudflare Turnstile helper |
| `passkey.dart` | Hosted V1.2 passkey ceremony and native platform passkey bridge |

Backend lives in a separate repo (`Akedly`). This SDK never talks to Akedly directly on the
customer's behalf — the customer's own backend proxies, holding the API key.

## Build and test

```bash
flutter test       # test/
flutter analyze
```

**`flutter`, not `dart`.** `pubspec.yaml` declares `flutter: sdk: flutter` as a real dependency, so
`dart test` / `dart analyze` cannot resolve the package at all — the Flutter SDK is not on the plain
Dart tool's path. `dart test` was written here until 2026-08-03 and never worked.

CI runs Flutter analysis and tests on stable. Native plugin builds and device acceptance still
require the platform jobs and hardware described in the feature plan. Never claim a build or test
run you did not actually see succeed.

## Conventions

- No code comments **except** doc comments (`///`). This is a public SDK — the doc comment on every
  public symbol is the contract customers read, so it is load-bearing. Change behaviour and you
  change the doc comment in the same edit. Inline `//` comments exist only to explain a non-obvious
  *why* — match that bar or omit.
- Results are immutable `const` constructors. Keep them const-constructible.
- Parsers are fed hostile external input (a callback URL). They must **never** throw — return a
  failed result instead. There are already five separate `catch` sites returning
  `reason: 'failed'`; that repetition is deliberate, not sloppiness.

## The browser requirement (non-negotiable, all platforms)

The hosted ceremony runs via **`flutter_web_auth_2`**, which delegates to the right browser surface
on each platform: **`ASWebAuthenticationSession` on iOS, a Chrome Custom Tab on Android**. Never
run the hosted ceremony in a `WebView` — platform passkeys will not work there. Native passkey
registration and authentication use the Akedly-owned method channel added in 1.2.0 and call
AuthenticationServices on iOS or Credential Manager on Android. The sibling SDKs are bound by the
same browser/native separation.

## The cross-SDK contract (kotlin / swift / js)

**Clauses 1–2 are identical across all four SDKs — do not diverge.** Clause 3's `reason`
vocabulary is deliberately **per-platform** and is NOT expected to match: Swift carries seven
values, Dart six, and Kotlin two, because a Custom Tab cannot signal a user cancel at all.
Aligning them would mean inventing values a platform cannot actually produce.

**`ceremonyOrigin` must be a bare origin** — `scheme://host[:port]`, no path, no trailing slash.
The four SDKs normalize it differently (JS reduces to a true origin because it reuses the value in
the `event.origin` equality check; the natives only prefix a URL), so a path-carrying or
multi-slash value behaves differently per platform. It fails visibly — the ceremony 404s — so this
is a documented input contract, not a code divergence to "fix".

1. **A verified result MUST carry a `resultToken`** (`AkedlyPasskey._fromParams`). A claimed-verified
   callback with no token is reported `verified: false`, `reason: 'no_proof'` — never as a trusted
   success. **Fail closed. This is the whole security property of the relayed result**, since the
   callback arrives over a custom scheme that cannot be trusted on its own.
2. **The relayed signal is not authoritative.** The customer confirms a sign-in by sending
   `resultToken` to their own backend, which verifies it **offline** by recomputing an HMAC with
   their Akedly API key. No polling, no server-to-server callback needed.
   - ⚠️ **That proof is only worth anything if the API key is NOT in the app.** The same key the
     README's OTP example sends from the device is the HMAC key, so an integrator doing both ships
     a forgeable proof. The README now says so; keep the warning when editing that section.
3. **`reason` vocabulary:** `null` when verified, else `'closed'` (user dismissed — `flutter_web_auth_2`
   throws code `CANCELED`), `'start_failed'`, `'busy'` (a ceremony is already in flight),
   `'no_proof'`, `'failed'` (unparseable callback), or a server `code`.
   - `'busy'` guards a real defect, not just a double-tap annoyance: `flutter_web_auth_2` keeps ONE
     global completer, so a second `authenticate()` displaces the first and its future never
     completes. The guard is `static` because the plugin state it protects is global.
   - ✅ **The `'busy'` guard is now covered — `test/passkey_ceremony_test.dart`, four tests**
     (2026-08-04): a second ceremony while one is in flight returns `'busy'` **and never reaches
     the plugin** (call count asserted, not just the result), and the guard is released on all
     three exits — completion, a thrown session, and a `CANCELED` dismissal followed by a retry.
     Written because the guard shipped untested: with the parser surface fully covered, deleting
     `_inFlight` left every test green.
   - ⚠️ **Those four tests have NEVER BEEN RUN — no Flutter toolchain on the authoring machine
     (2026-08-04).** They are written to compile against nothing but `dart:async`, `flutter_test`
     and this package, which is why `openCeremony` gained the `authenticator` seam: mocking the
     `flutter_web_auth_2` method channel would have bound the test to the plugin's internal channel
     name and to host-platform behaviour that differs under `flutter test` — both unverifiable here.
     **First run with a real toolchain: `flutter test`, and treat any failure as a defect in these
     tests, not in the guard** (the guard itself was verified by inspection).
   - `dev_dependencies` gained `flutter_test` (2026-08-04). Without it `flutter test` cannot launch
     at all: flutter_tools' generated bootstrap imports `package:flutter_test/flutter_test.dart`
     unconditionally. This was almost certainly why the suite had never run, and it means the 12
     pre-existing `package:test` tests were never green either — nobody had executed them.

## Decided items

- **`ineligible` — ✅ REMOVED FROM THE DOCS 2026-07-28.** The `AkedlyPasskeyResult.reason` doc comment documented it as a
  value; it is not one, and it has been removed from the doc comment. Do not reintroduce it.
  **Two things an earlier version of this note got wrong — do not re-plant them:**
  - It was **not** Dart-only. `akedly-shield-swift`'s README carried it too, and so did the JS SDK's
    docs. That false "this repo is clean" claim is why the Swift repo was nearly skipped in the sweep.
  - The SDK **can** surface it, by server-`code` passthrough (the `p['code'] ?? 'failed'` fallback in `_fromParams`, asserted by the
    server-`code` passthrough test). It is unreachable only because **no server sends that code** —
    not because the code path refuses it. "Nothing could ever emit it" was wrong on both halves.

  The real server-side set is `NO_PASSKEY`, `PASSKEY_DISABLED`, `INSUFFICIENT_QUOTA`,
  `BILLING_FAILED`, `CANCELLED`, `FAILED`.
- **`flutter_web_auth_2: ^4.1.0` is selected — ✅ RESOLVED 2026-09-24 (OI-H).** VERIFY proved that
  the 3.x Android integration still imports the removed v1 Registrar and cannot build with current
  Flutter tooling. The 4.1.0 archive removes that Registrar dependency while retaining Dart 2.15+
  and Flutter 3.0+ compatibility, but its `web` dependency requires the Flutter-pinned `web`
  0.5 line. VERIFY established Dart 3.3 and Flutter 3.22.3 as the smallest maintained
  compatible floors, so this package raises its public floors as a breaking 1.2.0 change to
  `sdk: >=3.3.0` and `flutter: >=3.22.3`; the iOS plugin target is iOS 12 and native
  passkey support itself still checks iOS 16 at runtime.

  This resolves the deferred pin decision for the hosted browser handoff without changing the
  native passkey contract. Physical-device acceptance on iOS and Android remains required before
  the 1.2.0 tag or pub.dev publication.

## Gotchas

### Native bridge

`AkedlyPasskey.register`, `authenticate`, and `isNativeSupported` use the package's
`akedly_shield/passkey` channel. The options cross the channel as a JSON string so the native
implementations retain the backend's WebAuthn field names. The iOS implementation ports the
accepted AuthenticationServices mapper and the Android implementation ports the accepted
Credential Manager 1.6.0 mapper in a package-specific namespace. Neither implementation makes a
network request or carries an API key. Keep the native in-flight guard separate from the hosted
`openCeremony` guard.

- `flutter_web_auth_2` throws a `PlatformException` with code `CANCELED` on user dismissal; any other
  code is an integration failure. The `on PlatformException` branch of `openCeremony` makes exactly that distinction — an
  integration bug must never be reported as "the user changed their mind". Preserve it.
- The ceremony origin is injectable so tests and QA can point at a local Auth-Gateway rather than
  production. Keep it injectable.

## Release and device acceptance

This section is internal release procedure and must not be copied into public package docs.
Before tagging or publishing `1.2.0`, verify `akedly.io` as the pub.dev publisher, run
`dart pub publish --dry-run`, and complete physical iPhone and Android acceptance against QA.
Require TEST-STRATEGY-S10 `S10-TS-3` (the physical re-proof journey) to be recorded as PASS, not
BLOCKED, before tagging or publishing. Resolve OI-16 with the owner before either irreversible
step. Until OI-16 is recorded, the current `LICENSE` holder `Copyright (c) 2026 Akedly` and the
iOS podspec author/contact `Akedly` / `developers@akedly.io` are provisional values; do not
change them or publish while they remain provisional.
The physical flow must show the native sheet, verify the response through the merchant backend,
and record the expected `https://akedly.io` or `android:apk-key-hash:` origin. Any OTP, SMS,
WhatsApp, or email used during acceptance goes only to `+201017438478`. Swift Package Manager
(`Package.swift`) support is deferred; use the Flutter CocoaPods integration.
