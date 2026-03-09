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

## Related Packages

- **JavaScript**: [`@akedly/shield`](https://www.npmjs.com/package/@akedly/shield)
- **Swift (iOS)**: [`AkedlyShield`](https://github.com/Akedly-Org/akedly-shield-swift)
- **Kotlin (Android)**: [`com.akedly.shield`](https://github.com/Akedly-Org/akedly-shield-kotlin)
