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

void main() async {
  await powExample();
}
