import 'dart:convert';
import 'dart:isolate';
import 'package:crypto/crypto.dart';

String _sha256Hex(String input) {
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

Future<int> solvePow(String challenge, int difficulty) async {
  final prefix = '0' * difficulty;
  var nonce = 0;
  while (true) {
    final hash = _sha256Hex('$challenge:$nonce');
    if (hash.startsWith(prefix)) {
      return nonce;
    }
    nonce++;
    if (nonce % 10000 == 0) {
      await Future.delayed(Duration.zero);
    }
  }
}

int _solvePowSync(List<dynamic> args) {
  final challenge = args[0] as String;
  final difficulty = args[1] as int;
  final prefix = '0' * difficulty;
  var nonce = 0;
  while (true) {
    final bytes = utf8.encode('$challenge:$nonce');
    final digest = sha256.convert(bytes);
    if (digest.toString().startsWith(prefix)) {
      return nonce;
    }
    nonce++;
  }
}

Future<int> solvePowInIsolate(String challenge, int difficulty) {
  return Isolate.run(() => _solvePowSync([challenge, difficulty]));
}
