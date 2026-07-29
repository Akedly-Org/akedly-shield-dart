# akedly_shield

Client-side PoW solver, Turnstile helper, and hosted passkey ceremony launcher for Akedly Shield V1.2 (Dart/Flutter).

## Installation

```yaml
dependencies:
  akedly_shield: ^1.1.0
```

## Quick Start

```dart
import 'package:akedly_shield/akedly_shield.dart';

// Solve PoW challenge
final nonce = await solvePow(challenge, difficulty);

// Or use an isolate for background computation
final nonce = await solvePowInIsolate(challenge, difficulty);
```

## API

### `solvePow(String challenge, int difficulty)`

Async solver that yields to the event loop every 10,000 iterations. Returns `Future<int>` (the nonce).

### `solvePowInIsolate(String challenge, int difficulty)`

Runs the solver in a separate Dart Isolate. Returns `Future<int>` (the nonce). Recommended for Flutter apps to avoid blocking the UI thread.

### `AkedlyTurnstile` (Flutter Widget)

Invisible widget that loads the Turnstile bridge page in a WebView.

```dart
AkedlyTurnstile(
  siteKey: 'your-turnstile-site-key',
  onToken: (token) {
    // Use token in your API request
  },
  onError: (error) {
    print('Error: $error');
  },
)
```

**Parameters:**
- `siteKey` (required) — Cloudflare Turnstile site key
- `onToken` (required) — callback with the Turnstile token
- `onError` — optional error callback
- `bridgeDomain` — bridge page domain (default: `turnstile.akedly.io`)

## Full Integration Example

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:akedly_shield/akedly_shield.dart';

Future<void> sendOTP(String phone, String apiKey, String pipelineID) async {
  // 1. Get challenge
  final challengeRes = await http.get(Uri.parse(
    'https://api.akedly.io/api/v1.2/transactions/challenge?APIKey=$apiKey&pipelineID=$pipelineID'
  ));
  final data = json.decode(challengeRes.body)['data'];

  // 2. Solve PoW
  Map<String, dynamic>? powSolution;
  if (data['challengeRequired'] == true) {
    final nonce = await solvePowInIsolate(data['challenge'], data['difficulty']);
    powSolution = {
      'challengeToken': data['challengeToken'],
      'nonce': nonce,
    };
  }

  // 3. Send OTP
  await http.post(
    Uri.parse('https://api.akedly.io/api/v1.2/transactions/send'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode({
      'APIKey': apiKey,
      'pipelineID': pipelineID,
      'verificationAddress': {'phoneNumber': phone},
      'powSolution': powSolution,
    }),
  );
}
```

## Algorithm

```
hash = SHA256(challenge + ":" + String(nonce))   // hex digest
valid = hash.startsWith("0" * difficulty)         // leading hex zeros
```

## Passkeys (V1.2)

Run a hosted V1.2 passkey ceremony on `auth.akedly.io/pk` from a Flutter app. The
ceremony runs in a **system authentication session** (`ASWebAuthenticationSession`
on iOS, a Custom Tab on Android, via [`flutter_web_auth_2`](https://pub.dev/packages/flutter_web_auth_2))
on the akedly.io origin — so platform passkeys (Face ID / Touch ID / fingerprint /
device PIN) work — and returns via a **deep link** to your app's custom scheme. **No
embedded WebView, no associated-domains / Digital Asset Links setup.**

```dart
import 'package:akedly_shield/akedly_shield.dart';

// 1. Your backend clears the gate + starts the ceremony:
//    POST /api/v1.2/transactions/passkey/auth-options
//      { …, returnTarget: { "url": "myapp://akedly-passkey" } }  // <-- REQUIRED for the resultToken
//    -> { data: { ceremonyToken } }
final ceremonyToken = await myBackend.startPasskeyAuth(phone); // or 404 NO_PASSKEY -> use OTP

// 2. Run it. `callbackScheme` is your app's registered URL scheme.
final result = await AkedlyPasskey.openCeremony(
  token: ceremonyToken,
  callbackScheme: 'myapp',
  // ceremonyOrigin: 'http://localhost:5174', // for QA
);

if (result.verified) {
  // 3. Confirm offline on YOUR backend — no polling needed. (Akedly also fires the pipeline's
  //    backend callback, if one is configured; it is unsigned, so the resultToken is the proof.)
  await myBackend.completeSignIn(result.resultToken!);
} else {
  // result.reason: "closed" (cancel) | "start_failed" | "no_proof" | "failed" | <server code>
  await runOtpFallback();
}
```

To **enroll** a passkey, pass the `enrollmentToken` from a successful OTP `/verify`
as the `token` instead — the API is identical; enrollment is proven on the next
successful sign-in.

> ⚠️ **The result is unproven unless you ask for the proof — on BOTH flows.** The hosted page relays
> a `resultToken` only to a **server-signed** return target. The `returnUrl` this SDK puts in the
> query is deliberately untrusted, so the token is stripped unless your backend passed `returnTarget`
> (e.g. `{ "url": "myapp://akedly-passkey" }`) — to `/auth-options` when authenticating, or to
> `/verify` when enrolling. Omit it and the ceremony still succeeds, but this SDK reports
> `verified: false` / `no_proof`, because it refuses to call an unproven result verified.
>
> - **Authenticating:** pass `returnTarget` at `/auth-options`, or you will never see `verified: true`
>   in the app and must reconcile against the pipeline's backend callback instead.
> - **Enrolling:** pass it at `/verify`, or treat the enroll result as advisory and let the next
>   successful sign-in be the proof. Do not gate your "passkey enabled" UI on the enroll result alone.

You must register the callback scheme once on Android (the standard
`flutter_web_auth_2` 3.x setup); iOS needs no setup.

The `callbackScheme` **must be lowercase** (`flutter_web_auth_2` validates it against
`^[a-z][a-z\d+.-]*$`); a mixed-case scheme is rejected by the plugin and surfaces as a
`start_failed` result.

**Android** — declare the intent filter on the **plugin's** `CallbackActivity` (not your
`MainActivity`) in `android/app/src/main/AndroidManifest.xml`, with your scheme in
`android:scheme`:

```xml
<activity
    android:name="com.linusu.flutter_web_auth_2.CallbackActivity"
    android:exported="true">
  <intent-filter android:label="flutter_web_auth_2">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="myapp" />
  </intent-filter>
</activity>
```

**iOS** — no setup required: `ASWebAuthenticationSession` receives the callback scheme
directly, so no `CFBundleURLSchemes` entry is needed.

### Verify the result (seamless — no polling)

A verified ceremony carries a **`resultToken`**: a compact, signed proof of the outcome. You
confirm a sign-in by verifying it **offline on your own backend** — no `/result` poll, no
server-to-server callback to Akedly. The token is HMAC-signed with **your account API key** (the
same secret you already use to create transactions), so only your backend — which holds that key
— can verify it.

> ⚠️ **Verify on your server, never in the app.** Your API key is a server secret. Do **not**
> embed it in the Flutter app or verify the token on-device. The app forwards `result.resultToken`
> to your backend; your backend verifies it and creates the session.

**Token format**

```
pkrt1.<base64url(payloadJSON)>.<base64url(signature)>
```

`payloadJSON` (a JSON object, before base64url):

```json
{ "v": 1, "purpose": "auth", "transactionId": "…", "pipelineId": "…",
  "verified": true, "iat": 1730000000000, "exp": 1730000120000 }
```

`iat`/`exp` are **milliseconds** since the Unix epoch (`exp` ≈ 2 minutes after `iat`).

**The signature — exactly what is HMAC'd, in this order**

```
signature = HMAC_SHA256( key = YOUR_API_KEY, message = "pkrt1." + base64url(payloadJSON) )
```

- **algorithm:** HMAC-SHA256.
- **key:** your account API key, as raw UTF-8 bytes.
- **message:** the ASCII string `"pkrt1."` immediately followed by the base64url payload segment
  — i.e. **the whole token with the trailing `.<signature>` removed**. The `pkrt1.` prefix **is
  part of the signed bytes**. (Equivalently: `token` up to, but not including, the final `.`.)
- **base64url is unpadded** (RFC 4648 §5: `+`→`-`, `/`→`_`, `=` stripped). Dart's
  `base64Url.decode` requires padding, so re-pad to a multiple of 4 with `=` first.

**Verification steps (do them all, in order)**

1. Reject if `token` doesn't start with `pkrt1.`.
2. Strip the `pkrt1.` prefix, then split the remainder on `.` — there must be **exactly
   two** segments, `dataSegment` and `sigSegment` (reject otherwise).
3. Require both segments to be **canonical** unpadded base64url: decode, re-encode, and
   reject unless the round-trip reproduces the segment exactly. (An alias of a segment's
   final character decodes to identical bytes, so a re-encoded token would still verify and
   bypass string-keyed single-use tracking.)
4. Compute `expected = HMAC_SHA256(apiKey, "pkrt1." + dataSegment)`.
5. **Constant-time-compare** `expected` against `base64url-decode(sigSegment)`. Reject on
   mismatch (forged / tampered).
6. `payload = JSON(base64url-decode(dataSegment))`.
7. Reject if `now_ms > payload.exp` (expired).
8. Require `payload.verified == true`.
9. Require `payload.transactionId ==` the transaction **you** started — this binds the proof to
   *this* sign-in. Only then create the session.

**Reference verifier — Node.js** (zero deps; portable to any backend language):

```javascript
import crypto from 'node:crypto';

export function verifyAkedlyResult(token, apiKey) {
  if (!apiKey) return null;                                       // fail closed on an empty key
  if (typeof token !== 'string' || !token.startsWith('pkrt1.')) return null;
  const parts = token.slice('pkrt1.'.length).split('.');
  if (parts.length !== 2) return null;                              // exactly two segments
  const [data, sig] = parts;
  const b64u = /^[A-Za-z0-9_-]+$/;                                  // strict unpadded base64url
  if (!b64u.test(data) || !b64u.test(sig)) return null;            // no alternate serializations
  // Canonical encoding only: an alias of the final char decodes to identical bytes,
  // which would bypass string-keyed single-use tracking.
  if (Buffer.from(data, 'base64url').toString('base64url') !== data ||
      Buffer.from(sig, 'base64url').toString('base64url') !== sig) return null;
  const expected = crypto.createHmac('sha256', apiKey).update('pkrt1.' + data).digest();
  const given = Buffer.from(sig, 'base64url');
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  const payload = JSON.parse(Buffer.from(data, 'base64url').toString());
  if (!payload.exp || Date.now() > payload.exp) return null;        // expired
  if (payload.verified !== true) return null;                       // only a verified outcome is trustworthy
  return payload; // verified + unexpired — the caller MUST still bind payload.transactionId to the ceremony it started
}
```

**Reference verifier — server-side Dart** (e.g. a Dart Frog / shelf backend; uses the same
`crypto` package this SDK already depends on):

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

String _pad(String s) => s + '=' * ((4 - s.length % 4) % 4);

String _unpadded(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Map<String, dynamic>? verifyAkedlyResult(String token, String apiKey) {
  if (apiKey.isEmpty) return null;                             // fail closed: never HMAC under an empty key
  const prefix = 'pkrt1.';
  if (!token.startsWith(prefix)) return null;
  final segments = token.substring(prefix.length).split('.');
  if (segments.length != 2) return null;                       // exactly two segments
  final dataSegment = segments[0];
  final sigSegment = segments[1];
  final b64u = RegExp(r'^[A-Za-z0-9_-]+$');                     // strict unpadded base64url
  if (!b64u.hasMatch(dataSegment) || !b64u.hasMatch(sigSegment)) return null;

  final expected = Hmac(sha256, utf8.encode(apiKey))
      .convert(utf8.encode('$prefix$dataSegment')) // "pkrt1." + dataSegment
      .bytes;

  // base64Url.decode throws on a malformed length (e.g. a sig whose length ≡ 1 mod 4) even
  // when the charset passes the regex — guard so crafted input is a clean reject, never a 500.
  final Map<String, dynamic> payload;
  try {
    final provided = base64Url.decode(_pad(sigSegment));
    final dataBytes = base64Url.decode(_pad(dataSegment));
    // Canonical encoding only: an alias of the final char decodes to identical bytes,
    // which would bypass string-keyed single-use tracking.
    if (_unpadded(provided) != sigSegment || _unpadded(dataBytes) != dataSegment) return null;
    if (!_constantTimeEquals(expected, provided)) return null;
    final decoded = json.decode(utf8.decode(dataBytes));
    if (decoded is! Map<String, dynamic>) return null;              // payload must be a JSON object
    payload = decoded;
  } on FormatException {
    return null;
  }
  final exp = payload['exp'];
  if (exp is! num || DateTime.now().millisecondsSinceEpoch > exp) return null; // missing/invalid or expired
  if (payload['verified'] != true) return null;                     // only a verified outcome is trustworthy
  return payload; // { verified, purpose, transactionId, pipelineId, ... }
}

// On your sign-in route, after the app POSTs { resultToken }:
//   final claim = verifyAkedlyResult(resultToken, akedlyApiKey);
//   if (claim != null && claim['transactionId'] == expectedTxId) {
//     createSession(user);
//   }
```

Treat the token like a one-time auth code: short-lived (~2 min) and accepted once.

### Local vs on-device testing

`ceremonyOrigin` decides which auth-gateway runs the WebAuthn ceremony — and therefore the
relying-party (RP) ID the passkey binds to. Pass `ceremonyOrigin: 'http://localhost:5174'` for
local development (RP=`localhost`, accepted by simulators/emulators); omit it on real devices to
use prod (`https://auth.akedly.io`, RP=`akedly.io`) — a `localhost` RP cannot bind on a physical
device.

- **iOS Simulator.** Run **iOS 16+** signed into iCloud (Simulator → Settings → sign in) so the
  platform authenticator can create/use passkeys; it reaches the host's `localhost` directly.
- **Android Emulator.** Use an image **with Google Play Services** and a configured **screen
  lock** — Credential Manager refuses without one. The emulator's `localhost` is the emulator
  itself, so tunnel the host with `adb reverse tcp:5174 tcp:5174` (and `tcp:4100` for your token
  backend) to keep the ceremony origin on `localhost`. Don't set `ceremonyOrigin` to `10.0.2.2` —
  over plain HTTP it isn't a trustworthy WebAuthn origin and binds the passkey to the wrong RP
  (`10.0.2.2` is fine for the token backend, not the ceremony).

> There is a full end-to-end V1.2 sandbox — web plus all four mobile SDK reference apps, with a
> headless Playwright + Chrome virtual-authenticator gate — for exercising this loop without a
> physical device.

### Without the SDK (open the page yourself)

`AkedlyPasskey` is a thin wrapper over `flutter_web_auth_2`. The ceremony is just a
URL you open in an auth session; the result comes back on your scheme:

```
https://auth.akedly.io/pk?token=<ceremonyToken>&returnUrl=myapp://akedly-passkey
   -> redirects to: myapp://akedly-passkey?verified=true&transactionId=…&resultToken=pkrt1.…
```

`AkedlyPasskey.buildUrl(...)` and `AkedlyPasskey.parseResult(uri)` /
`parseResultFromQuery(query)` are public if you want them without the session
wrapper. For production, prefer signing the `returnTarget` into the ceremony token
server-side via `/auth-options` over the `returnUrl` query param.

## Related Packages

- **JavaScript**: [`@akedly/shield`](https://www.npmjs.com/package/@akedly/shield)
- **Swift (iOS)**: [`AkedlyShield`](https://github.com/Akedly-Org/akedly-shield-swift)
- **Kotlin (Android)**: [`com.akedly.shield`](https://github.com/Akedly-Org/akedly-shield-kotlin)
