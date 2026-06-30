# akedly_shield

Client-side PoW solver and Turnstile helper for Akedly Shield V1.2 (Dart/Flutter).

## Installation

```yaml
dependencies:
  akedly_shield: ^1.0.0
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
//    POST /api/v1.2/transactions/passkey/auth-options -> { data: { ceremonyToken } }
final ceremonyToken = await myBackend.startPasskeyAuth(phone); // or a "no passkey" code -> use OTP

// 2. Run it. `callbackScheme` is your app's registered URL scheme.
final result = await AkedlyPasskey.openCeremony(
  token: ceremonyToken,
  callbackScheme: 'myapp',
  // ceremonyOrigin: 'http://localhost:5174', // for QA
);

if (result.verified) {
  // 3. Confirm offline on YOUR backend (no polling, no callback) — see below.
  await myBackend.completeSignIn(result.resultToken!);
} else {
  // result.reason: "closed" (cancel) | "ineligible" | "start_failed" | <server code>
  await runOtpFallback();
}
```

To **enroll** a passkey, pass the `enrollmentToken` from a successful OTP `/verify`
as the `token` instead — the API is identical; enrollment is proven on the next
successful sign-in.

You must register the callback scheme per platform once (the standard
`flutter_web_auth_2` setup): an `<intent-filter>` for `myapp` on Android, and
`CFBundleURLSchemes` in `Info.plist` on iOS.

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
  "verified": true, "iat": 1730000000000, "exp": 1730000600000 }
```

`iat`/`exp` are **milliseconds** since the Unix epoch (`exp` ≈ 10 minutes after `iat`).

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
3. Compute `expected = HMAC_SHA256(apiKey, "pkrt1." + dataSegment)`.
4. **Constant-time-compare** `expected` against `base64url-decode(sigSegment)`. Reject on
   mismatch (forged / tampered).
5. `payload = JSON(base64url-decode(dataSegment))`.
6. Reject if `now_ms > payload.exp` (expired).
7. Require `payload.verified == true`.
8. Require `payload.transactionId ==` the transaction **you** started — this binds the proof to
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
    if (!_constantTimeEquals(expected, provided)) return null;
    payload = json.decode(utf8.decode(base64Url.decode(_pad(dataSegment))))
        as Map<String, dynamic>;
  } on FormatException {
    return null;
  }
  final exp = payload['exp'];
  if (exp is! num || DateTime.now().millisecondsSinceEpoch > exp) return null; // missing/invalid or expired
  return payload; // { verified, purpose, transactionId, pipelineId, ... }
}

// On your sign-in route, after the app POSTs { resultToken }:
//   final claim = verifyAkedlyResult(resultToken, akedlyApiKey);
//   if (claim != null && claim['verified'] == true && claim['transactionId'] == expectedTxId) {
//     createSession(user);
//   }
```

Treat the token like a one-time auth code: short-lived (~10 min) and accepted once.

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
