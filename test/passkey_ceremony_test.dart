import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:akedly_shield/akedly_shield.dart';

/// Covers `openCeremony`'s in-flight guard and its release paths.
///
/// These live in their own file because they need `flutter_test` (the rest of the suite
/// runs on `package:test`), and because they are the only tests that drive `openCeremony`
/// rather than the pure parsers.
///
/// The guard was shipped untested: with the whole parser surface covered, deleting
/// `_inFlight` left every test green. Each test below is written so that removing the
/// piece of the guard it names turns it red — that is the property being bought here, not
/// the line coverage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<String> Function({
    required String url,
    required String callbackUrlScheme,
  }) original;

  const verifiedCallback =
      'demo://akedly-passkey?type=AKEDLY_PASSKEY_RESULT&purpose=auth'
      '&verified=true&transactionId=tx_1&resultToken=pkrt1.aaa.bbb';

  setUp(() => original = AkedlyPasskey.authenticator);
  tearDown(() => AkedlyPasskey.authenticator = original);

  test('a second ceremony while one is in flight returns busy, and does not '
      'disturb the first', () async {
    // The real defect this guards: flutter_web_auth_2 keeps ONE global completer, so a
    // second authenticate() displaces the first and strands its caller forever. The gate
    // below stands in for that pending session.
    final gate = Completer<String>();
    // Without this, a failing expect below leaves `gate` pending forever, so the first ceremony
    // never reaches its `finally` and `_inFlight` stays true — turning ONE real failure into four,
    // with the other three blaming the guard for a fault in this test.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(verifiedCallback);
    });
    var calls = 0;
    AkedlyPasskey.authenticator = ({
      required String url,
      required String callbackUrlScheme,
    }) {
      calls++;
      return gate.future;
    };

    final first =
        AkedlyPasskey.openCeremony(token: 'tok', callbackScheme: 'demo');
    final second =
        await AkedlyPasskey.openCeremony(token: 'tok', callbackScheme: 'demo');

    expect(second.verified, isFalse);
    expect(second.reason, 'busy');
    // The point of the guard is that the second call never reaches the plugin. Asserting
    // the result alone would still pass if it had called through and failed some other way.
    expect(calls, 1);

    gate.complete(verifiedCallback);
    final firstResult = await first;
    expect(firstResult.verified, isTrue);
    expect(firstResult.reason, isNull);
  });

  test('the guard is released after a ceremony completes', () async {
    AkedlyPasskey.authenticator = ({
      required String url,
      required String callbackUrlScheme,
    }) async =>
        verifiedCallback;

    final a = await AkedlyPasskey.openCeremony(token: 't', callbackScheme: 'demo');
    final b = await AkedlyPasskey.openCeremony(token: 't', callbackScheme: 'demo');

    expect(a.verified, isTrue);
    // A guard that never releases is a different bug of the same size: every later
    // ceremony would answer 'busy' for the life of the process.
    expect(b.verified, isTrue);
    expect(b.reason, isNull);
  });

  test('the guard is released when the session throws', () async {
    AkedlyPasskey.authenticator = ({
      required String url,
      required String callbackUrlScheme,
    }) async =>
        throw StateError('no browser');

    final a = await AkedlyPasskey.openCeremony(token: 't', callbackScheme: 'demo');
    final b = await AkedlyPasskey.openCeremony(token: 't', callbackScheme: 'demo');

    expect(a.reason, 'start_failed');
    // This is the `finally` under test. Without it the SDK would answer 'busy' here —
    // permanently stuck after a single failed launch, which is the worst version of it.
    expect(b.reason, 'start_failed');
  });

  test('a user-dismissed session reports closed and still releases the guard',
      () async {
    AkedlyPasskey.authenticator = ({
      required String url,
      required String callbackUrlScheme,
    }) async =>
        throw PlatformException(code: 'CANCELED');

    final dismissed =
        await AkedlyPasskey.openCeremony(token: 't', callbackScheme: 'demo');
    expect(dismissed.reason, 'closed');

    AkedlyPasskey.authenticator = ({
      required String url,
      required String callbackUrlScheme,
    }) async =>
        verifiedCallback;
    final retry =
        await AkedlyPasskey.openCeremony(token: 't', callbackScheme: 'demo');
    // Dismissing and retrying is the single most common real sequence; if the guard leaked
    // on the PlatformException path, the retry would be refused.
    expect(retry.verified, isTrue);
  });
}
