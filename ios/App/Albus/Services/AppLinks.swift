import Foundation

/// Pages outside the app that the App Store requires it to link to.
enum AppLinks {
    /// Apple's standard licence agreement. Albus has no terms of its own, and
    /// App Store Connect applies this one unless a custom EULA is uploaded.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Published on Netlify, from the `albus-app` project.
    static let privacy = URL(string: "https://albus-app.netlify.app/privacy/")!
    static let support = URL(string: "https://albus-app.netlify.app/support/")!

    /// Where a subscription is managed when Apple's own sheet can't be shown.
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}
