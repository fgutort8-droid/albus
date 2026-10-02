import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

/// Why a sign-in did not go through, in the words the student sees.
///
/// The SDK's errors are mapped once, here, so the screens never show a server
/// message. GoTrue answers a wrong code and an expired one with the same
/// `otp_expired`, so they share a message rather than guess which it was.
enum SignInError: Error, Equatable {
    case cancelled
    case offline
    case invalidEmail
    case codeRejected
    case tooManyRequests
    /// Adding Apple to an account made before sign-in existed, when that Apple
    /// ID already has its own account.
    case appleIDInUse
    /// The same, for an email address.
    case emailInUse
    case checkFailed
    case unavailable
    case storage
    case other

    var message: String? {
        switch self {
        case .cancelled: nil
        case .offline: "No connection. Check your internet and try again."
        case .invalidEmail: "That doesn't look like an email address."
        case .codeRejected: "That code didn't work or has expired. Check it, or send a new one."
        case .tooManyRequests: "Too many tries. Wait a minute, then try again."
        case .appleIDInUse: "This Apple ID already has an Albus account."
        case .emailInUse: "This email already has an Albus account."
        case .checkFailed: "The security check didn't go through. Try again."
        case .unavailable: "This way of signing in isn't available right now. Try the other one, or try again later."
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
            // Newer than this SDK's list of codes.
            if error.errorCode.rawValue == "email_address_invalid" { return .invalidEmail }
            switch error.errorCode {
            case .otpExpired, .invalidCredentials: return .codeRejected
            case .overEmailSendRateLimit, .overRequestRateLimit: return .tooManyRequests
            case .identityAlreadyExists: return .appleIDInUse
            case .emailExists: return .emailInUse
            case .captchaFailed: return .checkFailed
            case .validationFailed: return .invalidEmail
            case .signupDisabled, .providerDisabled, .emailProviderDisabled, .otpDisabled,
                 .manualLinkingDisabled, .emailAddressNotAuthorized:
                return .unavailable
            default: return .other
            }
        }
        return .other
    }
}

/// The address as typed, made fit to send: trimmed, lowercased, and only if it
/// could be an address at all. The server is the real check; this only spares
/// a request that cannot succeed.
enum EmailAddress {
    static func normalized(_ typed: String) -> String? {
        let email = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254,
              let at = email.firstIndex(of: "@"),
              at != email.startIndex,
              email[email.index(after: at)...].contains("."),
              !email.hasSuffix("."),
              email.filter({ $0 == "@" }).count == 1,
              !email.contains(where: \.isWhitespace)
        else { return nil }
        return email
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
