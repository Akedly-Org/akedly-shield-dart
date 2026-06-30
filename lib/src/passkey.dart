import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Result of a hosted V1.2 passkey ceremony (auth.akedly.io/pk), deep-linked
/// back to the app.
///
/// The relayed signal is **non-authoritative on its own**. Confirm a sign-in by
/// sending [resultToken] to YOUR backend, which verifies it **offline** by
/// recomputing an HMAC with your Akedly API key — no polling, no
/// server-to-server callback. See the README.
class AkedlyPasskeyResult {
  /// True only on a completed, server-verified ceremony.
  final bool verified;

  /// "auth" | "enroll" (null if the page didn't report it).
  final String? purpose;

  /// The passkey transaction/request id.
  final String? transactionId;

  /// Signed, offline-verifiable proof of a verified outcome. null otherwise.
  final String? resultToken;

  /// null when verified; else "closed" | "ineligible" | "start_failed" |
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

  /// Run the ceremony in a system auth session and return the parsed result.
  /// [callbackScheme] is your app's registered URL scheme (no `://`).
  static Future<AkedlyPasskeyResult> openCeremony({
    required String token,
    required String callbackScheme,
    String ceremonyOrigin = defaultOrigin,
  }) async {
    try {
      final url = buildUrl(token, callbackScheme, ceremonyOrigin: ceremonyOrigin);
      final callback = await FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: callbackScheme,
      );
      return parseResult(Uri.parse(callback));
    } on PlatformException catch (e) {
      // flutter_web_auth_2 throws code 'CANCELED' when the user dismisses the sheet; any
      // other platform error (no browser/Custom Tab handler, native auth-session failure)
      // is a setup failure, not a cancel — keep them distinguishable for the caller.
      final canceled = e.code.toUpperCase() == 'CANCELED';
      return AkedlyPasskeyResult(
          verified: false, reason: canceled ? 'closed' : 'start_failed');
    } catch (_) {
      return const AkedlyPasskeyResult(verified: false, reason: 'start_failed');
    }
  }

  /// Parse the deep-link redirect [uri] into a result.
  static AkedlyPasskeyResult parseResult(Uri uri) =>
      _fromParams(uri.queryParameters);

  /// Parse a result from a raw `key=value&…` query string. Pure (no platform
  /// deps) so it is unit-testable; [parseResult] is the `Uri` convenience.
  static AkedlyPasskeyResult parseResultFromQuery(String query) {
    final q = query.startsWith('?') ? query.substring(1) : query;
    return _fromParams(Uri.splitQueryString(q));
  }

  // Enforces the contract that a `verified` outcome MUST carry the offline-verifiable
  // [AkedlyPasskeyResult.resultToken]. A bare `…?verified=true` with no token (a malformed or
  // externally-triggered intent) is reported as verified=false, reason="no_proof" — never a
  // trusted success — so `result.resultToken!` can never be null on a verified result.
  static AkedlyPasskeyResult _fromParams(Map<String, String> p) {
    final claimed = p['verified'] == 'true';
    final token = p['resultToken'];
    final verified = claimed && token != null && token.isNotEmpty;
    return AkedlyPasskeyResult(
      verified: verified,
      purpose: p['purpose'],
      transactionId: p['transactionId'],
      resultToken: verified ? token : null,
      reason: verified ? null : (claimed ? 'no_proof' : (p['code'] ?? 'failed')),
    );
  }
}
