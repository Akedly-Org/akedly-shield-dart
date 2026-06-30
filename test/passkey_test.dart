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
    final r = AkedlyPasskey.parseResultFromQuery('verified=false&code=ineligible');
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
}
