import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Result of a hosted V1.2 passkey ceremony (auth.akedly.io/pk), deep-linked
/// back to the app.
///
/// The relayed signal is **non-authoritative on its own**. Confirm a sign-in by
/// sending [resultToken] to YOUR backend, which verifies it **offline** by
/// recomputing an HMAC with your Akedly API key — no polling, no
/// server-to-server callback to Akedly. See the README.
class AkedlyPasskeyResult {
  /// True only when the relay claims completion and includes a non-empty result token.
  /// The app must still send that token to its backend for HMAC and transaction verification.
  final bool verified;

  /// "auth" | "enroll" (null if the page didn't report it).
  final String? purpose;

  /// The passkey transaction/request id.
  final String? transactionId;

  /// Signed, offline-verifiable proof of a verified outcome. null otherwise.
  final String? resultToken;

  /// null when verified; else "closed" (user dismissed) | "start_failed" |
  /// "busy" (a ceremony is already in flight — a double-tap) |
  /// "no_proof" (claimed verified with a missing or blank result token) |
  /// "failed" (unparseable callback) |
  /// &lt;server code&gt;.
  final String? reason;

  const AkedlyPasskeyResult({
    required this.verified,
    this.purpose,
    this.transactionId,
    this.resultToken,
    this.reason,
  });
}

/// Hosted V1.2 passkey ceremony for Flutter (iOS + Android).
///
/// The ceremony runs in a system authentication session (`ASWebAuthenticationSession`
/// on iOS, a Custom Tab on Android, via `flutter_web_auth_2`) on the akedly.io
/// origin — so platform passkeys (Face ID / Touch ID / fingerprint / device PIN)
/// work — and returns the result through a deep link to your app's custom scheme.
/// No embedded WebView, no associated-domains / Digital Asset Links setup.
class AkedlyPasskey {
  static const String defaultOrigin = 'https://auth.akedly.io';
  static const Set<String> _reservedResultParams = {
    'type',
    'purpose',
    'verified',
    'transactionId',
    'code',
    'resultToken',
  };

  /// Build the ceremony URL: `<origin>/pk?token=…&returnUrl=<scheme>://akedly-passkey`.
  /// Pure (no platform deps) so it is unit-testable.
  static String buildUrl(
    String token,
    String callbackScheme, {
    String ceremonyOrigin = defaultOrigin,
  }) {
    final origin = ceremonyOrigin.endsWith('/')
        ? ceremonyOrigin.substring(0, ceremonyOrigin.length - 1)
        : ceremonyOrigin;
    final tok = Uri.encodeQueryComponent(token);
    final rt = Uri.encodeQueryComponent('$callbackScheme://akedly-passkey');
    return '$origin/pk?token=$tok&returnUrl=$rt';
  }

  static bool _inFlight = false;

  /// Run the ceremony in a system auth session and return the parsed result.
  /// [callbackScheme] is your app's registered URL scheme (no `://`).
  ///
  /// Calling this while a ceremony is still running resolves immediately with
  /// `reason: 'busy'` and leaves the running one untouched. This is what a double-tap on a
  /// sign-in button produces, and it is not cosmetic: `flutter_web_auth_2` keeps ONE global
  /// completer per app, so a second `authenticate()` displaces the first — whose future then
  /// never completes, stranding the first caller forever. The guard is static because
  /// `openCeremony` is static and the plugin's state is global; a per-instance guard would not
  /// match what is actually being protected.
  ///
  /// An integrator whose `else` branch falls through to OTP will fire a second OTP on every
  /// double-tap unless it handles `'busy'` — so treat it as "ignore, one is already running",
  /// not as a failure.
  static Future<AkedlyPasskeyResult> openCeremony({
    required String token,
    required String callbackScheme,
    String ceremonyOrigin = defaultOrigin,
  }) async {
    if (_inFlight) {
      return const AkedlyPasskeyResult(verified: false, reason: 'busy');
    }
    _inFlight = true;
    try {
      final url =
          buildUrl(token, callbackScheme, ceremonyOrigin: ceremonyOrigin);
      final callback = await FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: callbackScheme,
      );
      // A malformed return URL (e.g. an illegal percent-escape in the path) is a PARSE failure,
      // not a setup failure: use Uri.tryParse (returns null instead of throwing FormatException)
      // and bucket it as 'failed' to match the query parsers below — don't let the broad catch
      // mislabel it 'start_failed'.
      final uri = Uri.tryParse(callback);
      if (uri == null) {
        return const AkedlyPasskeyResult(verified: false, reason: 'failed');
      }
      return parseResult(uri);
    } on PlatformException catch (e) {
      // flutter_web_auth_2 throws code 'CANCELED' when the user dismisses the sheet; any
      // other platform error (no browser/Custom Tab handler, native auth-session failure)
      // is a setup failure, not a cancel — keep them distinguishable for the caller.
      final canceled = e.code.toUpperCase() == 'CANCELED';
      return AkedlyPasskeyResult(
          verified: false, reason: canceled ? 'closed' : 'start_failed');
    } catch (_) {
      return const AkedlyPasskeyResult(verified: false, reason: 'start_failed');
    } finally {
      // `finally`, not a reset at each return: every path above returns, and a throw that
      // escaped the catches would otherwise leave the SDK permanently 'busy' for the process.
      _inFlight = false;
    }
  }

  /// Parse the deep-link redirect [uri] into a result. `Uri.parse`/`tryParse` normalize a lone
  /// `%` to `%25`, but query decoding can still fail on crafted input: the percent decoder throws
  /// ArgumentError on a malformed escape (e.g. `%G1`) and FormatException on invalid UTF-8 bytes
  /// (e.g. `%FF`). Since this is a public parser fed external redirect input, a malformed query
  /// is a failed result, not a crash.
  static AkedlyPasskeyResult parseResult(Uri uri) {
    try {
      if (_hasDuplicateReservedParams(uri.queryParametersAll)) {
        return const AkedlyPasskeyResult(verified: false, reason: 'failed');
      }
      return _fromParams(uri.queryParameters);
    } on FormatException {
      return const AkedlyPasskeyResult(verified: false, reason: 'failed');
    } on ArgumentError {
      return const AkedlyPasskeyResult(verified: false, reason: 'failed');
    }
  }

  /// Parse a result from a raw `key=value&…` query string. Pure (no platform
  /// deps) so it is unit-testable; [parseResult] is the `Uri` convenience.
  static AkedlyPasskeyResult parseResultFromQuery(String query) {
    final q = query.startsWith('?') ? query.substring(1) : query;
    try {
      final params = _parseQuery(q);
      if (params == null) return _failedResult;
      return _fromParams(params);
    } on FormatException {
      return const AkedlyPasskeyResult(verified: false, reason: 'failed');
    } on ArgumentError {
      return const AkedlyPasskeyResult(verified: false, reason: 'failed');
    }
  }

  static bool _hasDuplicateReservedParams(Map<String, List<String>> params) {
    return _reservedResultParams.any((name) => (params[name]?.length ?? 0) > 1);
  }

  static Map<String, String>? _parseQuery(String query) {
    final params = <String, String>{};
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final separator = pair.indexOf('=');
      final rawName = separator < 0 ? pair : pair.substring(0, separator);
      final rawValue = separator < 0 ? '' : pair.substring(separator + 1);
      final name = Uri.decodeQueryComponent(rawName);
      if (_reservedResultParams.contains(name) && params.containsKey(name)) {
        return null;
      }
      params[name] = Uri.decodeQueryComponent(rawValue);
    }
    return params;
  }

  static const AkedlyPasskeyResult _failedResult =
      AkedlyPasskeyResult(verified: false, reason: 'failed');

  // Enforces the contract that a `verified` outcome MUST carry the offline-verifiable
  // [AkedlyPasskeyResult.resultToken]. A bare `…?verified=true` with no token (a malformed or
  // externally-triggered intent) is reported as verified=false, reason="no_proof" — never a
  // trusted success — so `result.resultToken!` can never be null on a verified result.
  static AkedlyPasskeyResult _fromParams(Map<String, String> p) {
    final claimed = p['verified'] == 'true';
    final token = p['resultToken'];
    final verified = claimed && token != null && token.trim().isNotEmpty;
    return AkedlyPasskeyResult(
      verified: verified,
      purpose: p['purpose'],
      transactionId: p['transactionId'],
      resultToken: verified ? token : null,
      reason:
          verified ? null : (claimed ? 'no_proof' : (p['code'] ?? 'failed')),
    );
  }
}
