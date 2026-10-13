import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:akedly_shield/akedly_shield.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AkedlyPasskey.nativeChannel, null);
  });

  test('preserves native options JSON without dropping fields', () async {
    final options = <String, dynamic>{
      'challenge': 'challenge-_',
      'rpId': 'akedly.io',
      'timeout': 120000,
      'userVerification': 'required',
      'allowCredentials': [
        <String, dynamic>{
          'id': 'credential-_1',
          'transports': null,
        },
        <String, dynamic>{
          'id': 'credential-_2',
          'transports': ['internal', 'hybrid'],
        },
      ],
      'extensions': <String, dynamic>{'unknownExtension': true},
    };
    final optionsSnapshot =
        jsonDecode(jsonEncode(options)) as Map<String, dynamic>;
    var calls = 0;
    String? optionsJson;
    String? method;
    Set<Object?>? argumentKeys;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AkedlyPasskey.nativeChannel, (call) async {
      calls++;
      method = call.method;
      final arguments = call.arguments as Map<Object?, Object?>;
      argumentKeys = arguments.keys.toSet();
      optionsJson = arguments['optionsJson'] as String;
      return jsonEncode(<String, dynamic>{
        'id': 'credential-_1',
        'rawId': 'credential-_1',
        'type': 'public-key',
        'response': <String, dynamic>{
          'clientDataJSON': 'client-data',
          'authenticatorData': 'authenticator-data',
          'signature': 'signature',
        },
        'clientExtensionResults': <String, dynamic>{},
        'authenticatorAttachment': 'platform',
      });
    });

    await AkedlyPasskey.authenticate(options);
    expect(options, optionsSnapshot);

    expect(calls, 1);
    expect(method, 'authenticate');
    expect(argumentKeys, {'optionsJson'});
    expect(optionsJson, isNotNull);
    final decoded = jsonDecode(optionsJson!);
    expect(decoded, optionsSnapshot);
    expect((decoded as Map<String, dynamic>)['timeout'], isA<int>());
  });

  test('omits a null native userHandle and preserves the assertion response',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AkedlyPasskey.nativeChannel, (call) async {
      return jsonEncode(<String, dynamic>{
        'id': 'credential-_1',
        'rawId': 'credential-_1',
        'type': 'public-key',
        'response': <String, dynamic>{
          'clientDataJSON': 'client-data',
          'authenticatorData': 'authenticator-data',
          'signature': 'signature',
          'userHandle': null,
        },
        'clientExtensionResults': <String, dynamic>{},
        'authenticatorAttachment': 'platform',
      });
    });

    final response = await AkedlyPasskey.authenticate(<String, dynamic>{
      'challenge': 'challenge-_',
      'rpId': 'akedly.io',
      'allowCredentials': [
        <String, dynamic>{'id': 'credential-_1', 'transports': null},
      ],
      'userVerification': 'required',
    });

    final assertionResponse = response['response'] as Map<String, dynamic>;
    expect(response['id'], 'credential-_1');
    expect(response['rawId'], 'credential-_1');
    expect(response['type'], 'public-key');
    expect(assertionResponse.containsKey('userHandle'), isFalse);
    expect(assertionResponse['clientDataJSON'], 'client-data');
    expect(assertionResponse['authenticatorData'], 'authenticator-data');
    expect(assertionResponse['signature'], 'signature');
    expect(response['clientExtensionResults'], <String, dynamic>{});
    expect(response['authenticatorAttachment'], 'platform');
  });

  test('maps an unknown native code to failed and preserves diagnostics',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AkedlyPasskey.nativeChannel, (call) async {
      throw PlatformException(
        code: 'providerGone',
        message: 'm',
        details: <String, dynamic>{'domError': 'NotAllowedError'},
      );
    });

    AkedlyPasskeyNativeException? caught;
    try {
      await AkedlyPasskey.authenticate(<String, dynamic>{
        'challenge': 'challenge-_',
        'rpId': 'akedly.io',
        'allowCredentials': [
          <String, dynamic>{'id': 'credential-_1'},
        ],
      });
    } on AkedlyPasskeyNativeException catch (error) {
      caught = error;
    }

    expect(caught, isNotNull);
    expect(caught!.reason, AkedlyPasskeyNativeReason.failed);
    expect(caught.domError, 'NotAllowedError');
    expect(caught.platformCode, 'providerGone');
    expect(caught.message, 'm');
  });

  test('reports missing native plugin as unsupported', () async {
    expect(await AkedlyPasskey.isNativeSupported(), isFalse);

    AkedlyPasskeyNativeException? caught;
    try {
      await AkedlyPasskey.register(<String, dynamic>{
        'challenge': 'challenge-_',
        'rp': <String, dynamic>{'id': 'akedly.io'},
        'user': <String, dynamic>{
          'name': 'qa',
          'id': 'user-_1',
        },
      });
    } on AkedlyPasskeyNativeException catch (error) {
      caught = error;
    }

    expect(caught, isNotNull);
    expect(caught!.reason, AkedlyPasskeyNativeReason.unsupported);
  });

  test('guards concurrent native calls and releases after cancellation',
      () async {
    final firstGate = Completer<String>();
    final firstStarted = Completer<void>();
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AkedlyPasskey.nativeChannel, (call) async {
      calls++;
      if (calls == 1) {
        firstStarted.complete();
        return firstGate.future;
      }
      return jsonEncode(<String, dynamic>{
        'id': 'credential-_1',
        'rawId': 'credential-_1',
        'type': 'public-key',
        'response': <String, dynamic>{
          'clientDataJSON': 'client-data',
          'authenticatorData': 'authenticator-data',
          'signature': 'signature',
        },
        'clientExtensionResults': <String, dynamic>{},
      });
    });

    final first = AkedlyPasskey.authenticate(<String, dynamic>{
      'challenge': 'challenge-_',
      'rpId': 'akedly.io',
      'allowCredentials': [<String, dynamic>{'id': 'credential-_1'}],
    });
    await firstStarted.future;

    AkedlyPasskeyNativeException? secondError;
    try {
      await AkedlyPasskey.authenticate(<String, dynamic>{
        'challenge': 'challenge-_',
        'rpId': 'akedly.io',
        'allowCredentials': [<String, dynamic>{'id': 'credential-_1'}],
      });
    } on AkedlyPasskeyNativeException catch (error) {
      secondError = error;
    }
    expect(secondError, isNotNull);
    expect(secondError!.reason, AkedlyPasskeyNativeReason.failed);
    expect(secondError.platformCode, 'busy');
    expect(calls, 1);

    firstGate.completeError(PlatformException(code: 'cancelled'));
    AkedlyPasskeyNativeException? firstError;
    try {
      await first;
    } on AkedlyPasskeyNativeException catch (error) {
      firstError = error;
    }
    expect(firstError, isNotNull);
    expect(firstError!.reason, AkedlyPasskeyNativeReason.cancelled);

    final third = await AkedlyPasskey.authenticate(<String, dynamic>{
      'challenge': 'challenge-_',
      'rpId': 'akedly.io',
      'allowCredentials': [<String, dynamic>{'id': 'credential-_1'}],
    });
    expect(third['type'], 'public-key');
    expect(calls, 2);
  });
}
