import AuthenticationServices
import Flutter
import Foundation

/// Flutter bridge for the Akedly native passkey ceremony.
public final class AkedlyShieldPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var activeCoordinator: AnyObject?

    /// Registers the plugin's method channel with Flutter.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "akedly_shield/passkey",
            binaryMessenger: registrar.messenger()
        )
        let instance = AkedlyShieldPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isNativeSupported":
            result(Self.isNativeSupported)
        case "register", "authenticate":
            handleCeremony(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static var isNativeSupported: Bool {
        if #available(iOS 16.0, *) {
            return true
        }
        return false
    }

    private func handleCeremony(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        guard #available(iOS 16.0, *) else {
            send(error: AkedlyPasskeyNativeError.unsupported, result: result)
            return
        }
        guard activeCoordinator == nil else {
            result(
                FlutterError(
                    code: "failed",
                    message: "A native passkey ceremony is already in flight.",
                    details: ["platformCode": "busy"]
                )
            )
            return
        }
        guard let arguments = call.arguments as? [String: Any],
              let optionsJson = arguments["optionsJson"] as? String,
              let optionsData = optionsJson.data(using: .utf8) else {
            send(error: AkedlyPasskeyNativeError.invalidOptions, result: result)
            return
        }

        do {
            let object = try AkedlyPasskeyNativeMapper.object(from: optionsData)
            if call.method == "register" {
                let options = try AkedlyPasskeyNativeMapper.registrationOptions(from: object)
                startRegistration(options: options, result: result)
            } else {
                let options = try AkedlyPasskeyNativeMapper.assertionOptions(from: object)
                startAuthentication(options: options, result: result)
            }
        } catch let error as AkedlyPasskeyNativeError {
            send(error: error, result: result)
        } catch {
            send(error: AkedlyPasskeyNativeError.invalidOptions, result: result)
        }
    }

    @available(iOS 16.0, *)
    private func startRegistration(
        options: AkedlyPasskeyRegistrationOptions,
        result: @escaping FlutterResult
    ) {
        let coordinator = AkedlyPasskeyNativePlatform.register(
            options: options,
            presentationAnchor: akedlyDefaultPresentationAnchor,
            completion: { [weak self] coordinator, authorizationResult in
                guard let self, self.activeCoordinator === coordinator else { return }
                self.activeCoordinator = nil
                self.finishRegistration(authorizationResult, result: result)
            }
        )
        activeCoordinator = coordinator
        coordinator.start(request: coordinator.authorizationRequest)
    }

    @available(iOS 16.0, *)
    private func startAuthentication(
        options: AkedlyPasskeyAssertionOptions,
        result: @escaping FlutterResult
    ) {
        let coordinator = AkedlyPasskeyNativePlatform.authenticate(
            options: options,
            presentationAnchor: akedlyDefaultPresentationAnchor,
            completion: { [weak self] coordinator, authorizationResult in
                guard let self, self.activeCoordinator === coordinator else { return }
                self.activeCoordinator = nil
                self.finishAuthentication(authorizationResult, result: result)
            }
        )
        activeCoordinator = coordinator
        coordinator.start(request: coordinator.authorizationRequest)
    }

    @available(iOS 16.0, *)
    private func finishRegistration(
        _ authorizationResult: Result<ASAuthorization, Error>,
        result: @escaping FlutterResult
    ) {
        do {
            let authorization = try authorizationResult.get()
            guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                  let attestationObject = credential.rawAttestationObject else {
                throw AkedlyPasskeyNativeError.unexpectedCredential
            }
            let object = AkedlyPasskeyNativeMapper.registrationObject(
                from: AkedlyPasskeyRegistrationResult(
                    credentialID: credential.credentialID,
                    clientDataJSON: credential.rawClientDataJSON,
                    attestationObject: attestationObject
                )
            )
            let data = try AkedlyPasskeyNativeMapper.data(from: object)
            guard let response = String(data: data, encoding: .utf8) else {
                throw AkedlyPasskeyNativeError.invalidOptions
            }
            result(response)
        } catch let error as AkedlyPasskeyNativeError {
            send(error: error, result: result)
        } catch {
            send(error: AkedlyPasskeyNativeError.failed(error), result: result)
        }
    }

    @available(iOS 16.0, *)
    private func finishAuthentication(
        _ authorizationResult: Result<ASAuthorization, Error>,
        result: @escaping FlutterResult
    ) {
        do {
            let authorization = try authorizationResult.get()
            guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                throw AkedlyPasskeyNativeError.unexpectedCredential
            }
            let object = AkedlyPasskeyNativeMapper.assertionObject(
                from: AkedlyPasskeyAssertionResult(
                    credentialID: credential.credentialID,
                    clientDataJSON: credential.rawClientDataJSON,
                    authenticatorData: credential.rawAuthenticatorData,
                    signature: credential.signature,
                    userID: credential.userID
                )
            )
            let data = try AkedlyPasskeyNativeMapper.data(from: object)
            guard let response = String(data: data, encoding: .utf8) else {
                throw AkedlyPasskeyNativeError.invalidOptions
            }
            result(response)
        } catch let error as AkedlyPasskeyNativeError {
            send(error: error, result: result)
        } catch {
            send(error: AkedlyPasskeyNativeError.failed(error), result: result)
        }
    }

    private func send(error: Error, result: @escaping FlutterResult) {
        let nativeError: AkedlyPasskeyNativeError
        if let error = error as? AkedlyPasskeyNativeError {
            nativeError = error
        } else {
            nativeError = .failed(error)
        }
        let code: String
        switch nativeError {
        case .unsupported:
            code = "unsupported"
        case .cancelled:
            code = "cancelled"
        case .invalidOptions:
            code = "invalidOptions"
        case .failed(_), .unexpectedCredential:
            code = "failed"
        }
        var details: [String: String] = [:]
        if case .unexpectedCredential = nativeError {
            details["platformCode"] = "unexpectedCredential"
        }
        if #available(iOS 13.0, *) {
            if case let .failed(underlying) = nativeError,
               let authorizationError = underlying as? ASAuthorizationError {
                details["platformCode"] = String(authorizationError.code.rawValue)
            }
        }
        result(
            FlutterError(
                code: code,
                message: nativeMessage(for: nativeError),
                details: details.isEmpty ? nil : details
            )
        )
    }

    private func nativeMessage(for error: AkedlyPasskeyNativeError) -> String {
        switch error {
        case .unsupported:
            return "Native passkeys require iOS 16 or newer."
        case .cancelled:
            return "The native passkey ceremony was cancelled."
        case .invalidOptions:
            return "The native passkey options are invalid."
        case .unexpectedCredential:
            return "Authentication Services returned an unexpected credential."
        case let .failed(underlying):
            return underlying.localizedDescription
        }
    }
}
