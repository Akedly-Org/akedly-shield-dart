/// Stable failure categories for a native passkey ceremony.
enum AkedlyPasskeyNativeReason {
  /// The current device or credential provider cannot run native passkeys.
  unsupported,

  /// The user dismissed the native passkey sheet.
  cancelled,

  /// No matching passkey was available for the request.
  noCredential,

  /// The options were not valid WebAuthn JSON for the native platform.
  invalidOptions,

  /// The platform or ceremony failed for another reason.
  failed,
}

/// Error raised when a native passkey ceremony cannot produce a response.
class AkedlyPasskeyNativeException implements Exception {
  /// Creates a native passkey error.
  const AkedlyPasskeyNativeException({
    required this.reason,
    required this.message,
    this.domError,
    this.platformCode,
  });

  /// The stable failure category an app can use to select a fallback.
  final AkedlyPasskeyNativeReason reason;

  /// A diagnostic message suitable for local logging or developer tooling.
  final String message;

  /// The WebAuthn DOM error name when the provider reports one.
  final String? domError;

  /// A diagnostic code from the native bridge, when one is available.
  ///
  /// Akedly reserves `busy`, `noActivity`, and `unexpectedCredential` for
  /// bridge-level outcomes. Other values are raw platform diagnostics, such
  /// as a Credential Manager exception type or an Authentication Services
  /// error code.
  final String? platformCode;

  @override
  String toString() {
    final fields = <String>[
      'reason: ${reason.name}',
      'message: $message',
      if (domError != null) 'domError: $domError',
      if (platformCode != null) 'platformCode: $platformCode',
    ];
    return 'AkedlyPasskeyNativeException(${fields.join(', ')})';
  }
}
