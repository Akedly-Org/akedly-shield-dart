import AuthenticationServices
import Foundation
import UIKit

enum AkedlyPasskeyNativeError: Error {
    case unsupported
    case cancelled
    case invalidOptions
    case failed(Error)
    case unexpectedCredential
}

extension Data {
    func akedlyBase64Url() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(akedlyBase64Url value: String) {
        guard value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                return true
            default:
                return false
            }
        }) else {
            return nil
        }

        let remainder = value.utf8.count % 4
        guard remainder != 1 else { return nil }
        let padding = (4 - remainder) % 4
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: padding)
        guard let decoded = Data(base64Encoded: standard),
              decoded.akedlyBase64Url() == value else {
            return nil
        }
        self = decoded
    }
}

struct AkedlyPasskeyRegistrationOptions {
    let challenge: Data
    let rpId: String
    let userName: String
    let userID: Data
    let excludedCredentialIDs: [Data]
}

struct AkedlyPasskeyAssertionOptions {
    let challenge: Data
    let rpId: String
    let allowedCredentialIDs: [Data]
}

struct AkedlyPasskeyRegistrationResult {
    let credentialID: Data
    let clientDataJSON: Data
    let attestationObject: Data
}

struct AkedlyPasskeyAssertionResult {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data
    let userID: Data?
}

enum AkedlyPasskeyNativeMapper {
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw AkedlyPasskeyNativeError.invalidOptions
        }
        return dictionary
    }

    static func data(from object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AkedlyPasskeyNativeError.invalidOptions
        }
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw AkedlyPasskeyNativeError.invalidOptions
        }
    }

    static func registrationOptions(
        from object: [String: Any]
    ) throws -> AkedlyPasskeyRegistrationOptions {
        guard let challengeValue = object["challenge"] as? String,
              let challenge = Data(akedlyBase64Url: challengeValue),
              !challenge.isEmpty,
              let relyingParty = object["rp"] as? [String: Any],
              let rpId = relyingParty["id"] as? String,
              !rpId.isEmpty,
              let user = object["user"] as? [String: Any],
              let userName = user["name"] as? String,
              !userName.isEmpty,
              let userIDValue = user["id"] as? String,
              let userID = Data(akedlyBase64Url: userIDValue),
              !userID.isEmpty else {
            throw AkedlyPasskeyNativeError.invalidOptions
        }

        let excludedCredentialIDs = try credentialIDs(
            from: object["excludeCredentials"],
            required: false
        )
        return AkedlyPasskeyRegistrationOptions(
            challenge: challenge,
            rpId: rpId,
            userName: userName,
            userID: userID,
            excludedCredentialIDs: excludedCredentialIDs
        )
    }

    static func assertionOptions(
        from object: [String: Any]
    ) throws -> AkedlyPasskeyAssertionOptions {
        guard let challengeValue = object["challenge"] as? String,
              let challenge = Data(akedlyBase64Url: challengeValue),
              !challenge.isEmpty,
              let rpId = object["rpId"] as? String,
              !rpId.isEmpty else {
            throw AkedlyPasskeyNativeError.invalidOptions
        }

        let allowedCredentialIDs = try credentialIDs(
            from: object["allowCredentials"],
            required: true
        )
        return AkedlyPasskeyAssertionOptions(
            challenge: challenge,
            rpId: rpId,
            allowedCredentialIDs: allowedCredentialIDs
        )
    }

    static func registrationObject(
        from result: AkedlyPasskeyRegistrationResult
    ) -> [String: Any] {
        let credentialID = result.credentialID.akedlyBase64Url()
        return [
            "id": credentialID,
            "rawId": credentialID,
            "type": "public-key",
            "response": [
                "clientDataJSON": result.clientDataJSON.akedlyBase64Url(),
                "attestationObject": result.attestationObject.akedlyBase64Url()
            ],
            "clientExtensionResults": [:],
            "authenticatorAttachment": "platform"
        ]
    }

    static func assertionObject(
        from result: AkedlyPasskeyAssertionResult
    ) -> [String: Any] {
        let credentialID = result.credentialID.akedlyBase64Url()
        var response: [String: Any] = [
            "clientDataJSON": result.clientDataJSON.akedlyBase64Url(),
            "authenticatorData": result.authenticatorData.akedlyBase64Url(),
            "signature": result.signature.akedlyBase64Url()
        ]
        if let userID = result.userID {
            response["userHandle"] = userID.akedlyBase64Url()
        }
        return [
            "id": credentialID,
            "rawId": credentialID,
            "type": "public-key",
            "response": response,
            "clientExtensionResults": [:],
            "authenticatorAttachment": "platform"
        ]
    }

    private static func credentialIDs(
        from value: Any?,
        required: Bool
    ) throws -> [Data] {
        guard let value else {
            if required { throw AkedlyPasskeyNativeError.invalidOptions }
            return []
        }
        guard let descriptors = value as? [Any] else {
            throw AkedlyPasskeyNativeError.invalidOptions
        }
        if required && descriptors.isEmpty {
            throw AkedlyPasskeyNativeError.invalidOptions
        }
        return try descriptors.map { descriptor in
            guard let dictionary = descriptor as? [String: Any],
                  let idValue = dictionary["id"] as? String,
                  let id = Data(akedlyBase64Url: idValue),
                  !id.isEmpty else {
                throw AkedlyPasskeyNativeError.invalidOptions
            }
            return id
        }
    }
}

@available(iOS 16.0, *)
enum AkedlyPasskeyNativePlatform {
    static func register(
        options: AkedlyPasskeyRegistrationOptions,
        presentationAnchor: @escaping () -> ASPresentationAnchor,
        completion: @escaping (AkedlyPasskeyNativeCoordinator, Result<ASAuthorization, Error>) -> Void
    ) -> AkedlyPasskeyNativeCoordinator {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rpId
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: options.challenge,
            name: options.userName,
            userID: options.userID
        )
        request.userVerificationPreference = .required
        if #available(iOS 17.4, *) {
            request.excludedCredentials = options.excludedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        let coordinator = AkedlyPasskeyNativeCoordinator(
            authorizationRequest: request,
            presentationAnchor: presentationAnchor,
            completion: completion
        )
        return coordinator
    }

    static func authenticate(
        options: AkedlyPasskeyAssertionOptions,
        presentationAnchor: @escaping () -> ASPresentationAnchor,
        completion: @escaping (AkedlyPasskeyNativeCoordinator, Result<ASAuthorization, Error>) -> Void
    ) -> AkedlyPasskeyNativeCoordinator {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rpId
        )
        let request = provider.createCredentialAssertionRequest(
            challenge: options.challenge
        )
        request.allowedCredentials = options.allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        request.userVerificationPreference = .required
        let coordinator = AkedlyPasskeyNativeCoordinator(
            authorizationRequest: request,
            presentationAnchor: presentationAnchor,
            completion: completion
        )
        return coordinator
    }
}

@available(iOS 16.0, *)
final class AkedlyPasskeyNativeCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    let authorizationRequest: ASAuthorizationRequest
    private let presentationAnchor: () -> ASPresentationAnchor
    private let completion: (AkedlyPasskeyNativeCoordinator, Result<ASAuthorization, Error>) -> Void
    private var controller: ASAuthorizationController?
    private var finished = false

    init(
        authorizationRequest: ASAuthorizationRequest,
        presentationAnchor: @escaping () -> ASPresentationAnchor,
        completion: @escaping (AkedlyPasskeyNativeCoordinator, Result<ASAuthorization, Error>) -> Void
    ) {
        self.authorizationRequest = authorizationRequest
        self.presentationAnchor = presentationAnchor
        self.completion = completion
        super.init()
    }

    func start(request: ASAuthorizationRequest) {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func cancel() {
        controller?.cancel()
        finish(.failure(AkedlyPasskeyNativeError.cancelled))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            finish(.failure(AkedlyPasskeyNativeError.cancelled))
        } else {
            finish(.failure(AkedlyPasskeyNativeError.failed(error)))
        }
    }

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        presentationAnchor()
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        guard !finished else { return }
        finished = true
        controller = nil
        completion(self, result)
    }
}

@available(iOS 13.0, *)
func akedlyDefaultPresentationAnchor() -> ASPresentationAnchor {
    let windowScenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
    let scene = windowScenes.first(where: { $0.activationState == .foregroundActive }) ?? windowScenes.first
    if let scene = scene {
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first ?? UIWindow(windowScene: scene)
    }
    return UIWindow()
}
