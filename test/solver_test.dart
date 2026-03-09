import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:akedly_shield/akedly_shield.dart';

String computeHash(String challenge, int nonce) {
  final input = '$challenge:$nonce';
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

bool verifyNonce(String challenge, int nonce, int difficulty) {
  final hash = computeHash(challenge, nonce);
  final prefix = '0' * difficulty;
  return hash.startsWith(prefix);
}

void main() {
  const challenge =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test('solvePow difficulty 3 produces valid nonce', () async {
    final nonce = await solvePow(challenge, 3);
    expect(verifyNonce(challenge, nonce, 3), isTrue);
  });

  test('solvePow difficulty 4 produces valid nonce', () async {
    final nonce = await solvePow(challenge, 4);
    expect(verifyNonce(challenge, nonce, 4), isTrue);
  });

  test('solvePowInIsolate difficulty 3 produces valid nonce', () async {
    final nonce = await solvePowInIsolate(challenge, 3);
    expect(verifyNonce(challenge, nonce, 3), isTrue);
  });

  test('solvePowInIsolate difficulty 4 produces same nonce as solvePow',
      () async {
    final nonce1 = await solvePow(challenge, 4);
    final nonce2 = await solvePowInIsolate(challenge, 4);
    expect(nonce1, equals(nonce2));
  });

  test('solvePow difficulty 1 edge case', () async {
    final nonce = await solvePow(challenge, 1);
    expect(verifyNonce(challenge, nonce, 1), isTrue);
  });
}
