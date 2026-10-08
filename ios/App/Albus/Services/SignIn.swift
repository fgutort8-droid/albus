import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

/// Why a sign-in did not go through, in the words the student sees.
///
/// The SDK's errors are mapped once, here, so the screens never show a server
/// message.
enum SignInError: Error, Equatable {
    case cancelled
    case offline
    case tooManyRequests
    /// Adding Apple to an account made before sign-in existed, when that Apple
    /// ID already has its own account.
    case appleIDInUse
    case unavailable
    case storage
    case other

    var message: String? {
        switch self {
        case .cancelled: nil
        case .offline: "No connection. Check your internet and try again."
        case .tooManyRequests: "Too many tries. Wait a minute, then try again."
        case .appleIDInUse: "This Apple ID already has an Albus account."
        case .unavailable: "Sign in with Apple isn't available right now. Please try again later."
        case .storage: SessionStorageUnavailable().errorDescription
        case .other: "Couldn't sign in. Please try again."
        }
    }

    static func from(_ error: Error) -> SignInError {
        if let error = error as? SignInError { return error }
        if error is SessionStorageUnavailable { return .storage }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                return .other
            }
        }
        if let error = error as? ASAuthorizationError, error.code == .canceled { return .cancelled }
        if let error = error as? AuthError {
            switch error.errorCode {
            case .overRequestRateLimit: return .tooManyRequests
            // Linking can also meet the Apple ID's email on another account.
            case .identityAlreadyExists, .emailExists: return .appleIDInUse
            case .signupDisabled, .providerDisabled, .manualLinkingDisabled: return .unavailable
            default: return .other
            }
        }
        return .other
    }
}

/// The parts of Sign in with Apple that are plain values.
enum AppleSignIn {
    /// A fresh random value per attempt. Apple signs its hash into the ID
    /// token and Supabase checks it against this, so a token lifted from one
    /// attempt cannot be replayed into another.
    static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The ID token from a completed authorization, if Apple sent one.
    static func identityToken(from authorization: ASAuthorization) -> String? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Asks Apple to confirm the student, without a button.
///
/// Deleting an account that uses Sign in with Apple needs a fresh
/// authorization code, which the server trades with Apple for a token and then
/// revokes. Apple requires that revocation, and a code lasts five minutes, so
/// it is asked for at the moment of deletion rather than kept.
@MainActor
final class AppleConfirmation: NSObject, ASAuthorizationControllerDelegate,
                               ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    /// The authorization code Apple issues once the student confirms.
    func authorizationCode() async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let authorization = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.authorizationCode,
              let code = String(data: data, encoding: .utf8)
        else { throw SignInError.other }
        return code
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { finish(.success(authorization)) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }
}
