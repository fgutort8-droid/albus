import Foundation

/// Pages outside the app that the App Store requires it to link to.
enum AppLinks {
    /// Albus's terms of service. Apple's standard licence agreement still
    /// covers the app itself (no custom EULA is uploaded to App Store Connect),
    /// and the terms page links it in its first paragraph.
    static let terms = URL(string: "https://albus-app.netlify.app/terms/")!

    /// Published on Netlify, from the `albus-app` project.
    static let privacy = URL(string: "https://albus-app.netlify.app/privacy/")!
    static let support = URL(string: "https://albus-app.netlify.app/support/")!

    /// Where a subscription is managed when Apple's own sheet can't be shown.
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}
