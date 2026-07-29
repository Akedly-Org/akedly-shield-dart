import 'package:test/test.dart';
import 'package:akedly_shield/akedly_shield.dart';

void main() {
  test('buildUrl encodes token and returnUrl', () {
    final url = AkedlyPasskey.buildUrl('pk1.abc', 'myapp');
    expect(url.startsWith('https://auth.akedly.io/pk?'), isTrue);
    expect(url.contains('token=pk1.abc'), isTrue);
    expect(url.contains('returnUrl=myapp%3A%2F%2Fakedly-passkey'), isTrue);
  });

  test('buildUrl trims a trailing slash on the origin', () {
    final url = AkedlyPasskey.buildUrl('t', 'demo',
        ceremonyOrigin: 'http://localhost:5174/');
    expect(url.contains('//localhost:5174/pk?'), isTrue);
  });

  test('parseResultFromQuery reads a verified result', () {
    final r = AkedlyPasskey.parseResultFromQuery(
        'type=AKEDLY_PASSKEY_RESULT&purpose=auth&verified=true&transactionId=tx_9&resultToken=pkrt1.aaa.bbb');
    expect(r.verified, isTrue);
    expect(r.purpose, equals('auth'));
    expect(r.transactionId, equals('tx_9'));
    expect(r.resultToken, equals('pkrt1.aaa.bbb'));
    expect(r.reason, isNull);
  });

  test('parseResultFromQuery carries a failure code as the reason', () {
    final r =
        AkedlyPasskey.parseResultFromQuery('verified=false&code=ineligible');
    expect(r.verified, isFalse);
    expect(r.resultToken, isNull);
    expect(r.reason, equals('ineligible'));
  });

  test('parseResult defaults a missing verified flag to failed', () {
    final r = AkedlyPasskey.parseResult(Uri.parse('myapp://akedly-passkey'));
    expect(r.verified, isFalse);
    expect(r.reason, equals('failed'));
  });

  test('verified=true without a resultToken is not trusted', () {
    final r = AkedlyPasskey.parseResultFromQuery('verified=true');
    expect(r.verified, isFalse);
    expect(r.resultToken, isNull);
    expect(r.reason, equals('no_proof'));
  });

  test('verified=true with a whitespace-only resultToken is not trusted', () {
    final r =
        AkedlyPasskey.parseResultFromQuery('verified=true&resultToken=%20%20');
    expect(r.verified, isFalse);
    expect(r.reason, equals('no_proof'));
  });

  test('a malformed query encoding is a failed result, not a crash', () {
    final r =
        AkedlyPasskey.parseResultFromQuery('verified=%&resultToken=pkrt1.a.b');
    expect(r.verified, isFalse);
    expect(r.reason, equals('failed'));
  });

  test('an invalid percent-escape digit is a failed result, not a crash', () {
    final r = AkedlyPasskey.parseResultFromQuery(
        'verified=%G1&resultToken=pkrt1.a.b');
    expect(r.verified, isFalse);
    expect(r.reason, equals('failed'));
  });

  test('invalid UTF-8 in a query value is a failed result, not a crash', () {
    final r = AkedlyPasskey.parseResultFromQuery('verified=%FF');
    expect(r.verified, isFalse);
    expect(r.reason, equals('failed'));
  });

  test('verified=true with an empty resultToken is not trusted', () {
    final r = AkedlyPasskey.parseResultFromQuery('verified=true&resultToken=');
    expect(r.verified, isFalse);
    expect(r.resultToken, isNull);
    expect(r.reason, equals('no_proof'));
  });

  test('duplicate reserved result params fail closed', () {
    final reservedParams = <String, String>{
      'type': 'AKEDLY_PASSKEY_RESULT',
      'purpose': 'auth',
      'verified': 'true',
      'transactionId': 'tx_9',
      'code': 'ineligible',
      'resultToken': 'pkrt1.aaa.bbb',
    };
    final baseQuery = reservedParams.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('&');
    for (final entry in reservedParams.entries) {
      final r = AkedlyPasskey.parseResultFromQuery(
          '$baseQuery&${entry.key}=${entry.value}');
      expect(r.verified, isFalse, reason: 'duplicate ${entry.key}');
      expect(r.resultToken, isNull);
      expect(r.reason, equals('failed'));

      final uriResult = AkedlyPasskey.parseResult(Uri.parse(
          'myapp://akedly-passkey?$baseQuery&${entry.key}=${entry.value}'));
      expect(uriResult.verified, isFalse, reason: 'URI duplicate ${entry.key}');
      expect(uriResult.resultToken, isNull);
      expect(uriResult.reason, equals('failed'));
    }
  });
}
