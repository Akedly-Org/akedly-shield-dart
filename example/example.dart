import 'package:akedly_shield/akedly_shield.dart';

// PoW solver example (Dart CLI or Flutter)
Future<void> powExample() async {
  const challenge = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const difficulty = 4;

  // Option 1: Async solver (yields to event loop)
  final nonce = await solvePow(challenge, difficulty);
  print('Solved! Nonce: $nonce');

  // Option 2: Isolate solver (runs on separate thread)
  final nonce2 = await solvePowInIsolate(challenge, difficulty);
  print('Solved in isolate! Nonce: $nonce2');
}

// Flutter Turnstile widget example:
//
// AkedlyTurnstile(
//   siteKey: 'your-turnstile-site-key',
//   onToken: (token) {
//     print('Got Turnstile token: $token');
//     // Include token in your API request as turnstileToken
//   },
//   onError: (error) {
//     print('Turnstile error: $error');
//   },
// )

// Hosted passkey ceremony example (Flutter)
Future<void> passkeyExample() async {
  // Your backend calls Akedly V1.2 and returns the ceremony token; the app never holds the API key.
  // It MUST pass returnTarget: { "url": "your-app://akedly-passkey" } to /auth-options. The hosted
  // /pk page relays a resultToken only to a server-signed target, so omitting it makes even a
  // SUCCESSFUL sign-in arrive here as no_proof — with no error and no log.
  // final token = await yourBackend.createPasskeyCeremony();
  const token = '<ceremony-token-from-your-backend>';
  final result = await AkedlyPasskey.openCeremony(
    token: token,
    callbackScheme: 'your-app',
  );

  if (result.verified) {
    // Send this to YOUR backend; the API key is secret, so never verify on-device.
    // await yourBackend.verifyPasskeyResult(result.resultToken!);
    print('Verified ceremony proof returned');
  } else if (result.reason == 'no_proof') {
    // Fail-closed: the callback claimed success but carried no resultToken, so it is not trusted.
    // On ENROLLMENT this is expected without a returnTarget — the passkey IS created; let the next
    // sign-in prove it. On AUTH it means your backend omitted returnTarget (or the callback was
    // forged) — fall back to OTP, or reconcile against the backend callback before re-sending.
    print('Ceremony completed without sign-in proof');
  } else if (result.reason == 'closed') {
    print('Ceremony closed');
  } else if (result.reason == 'start_failed') {
    print('Ceremony failed to start');
  } else {
    print('Ceremony failed: ${result.reason}');
  }
}

void main() async {
  await powExample();
}
