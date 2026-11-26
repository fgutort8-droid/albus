import SwiftUI
import AlbusCore

/// A quiet warning that plan figures are stale, shared by every screen that
/// presents a plan or allowance. Retry asks the server again; dismissing only
/// hides this message and cannot change an entitlement.
struct EntitlementRefreshNotice: View {
    @Environment(EntitlementService.self) private var entitlements

    var body: some View {
        // A quiet line, not an amber strip: nothing is lost, and the figures
        // shown are the last ones the server confirmed. Saying when is what
        // makes "the last values" something a student can judge.
        HStack(spacing: Tokens.Spacing.s) {
            Text(Self.sentence(lastCheckedAt: entitlements.lastCheckedAt))
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Check again") {
                Task { await entitlements.refresh() }
            }
            .font(Tokens.Typography.label)
            .fontWeight(.semibold)
            .foregroundStyle(Tokens.Palette.accent)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .disabled(entitlements.isLoading)
            .accessibilityIdentifier("retryEntitlementRefresh")

            Button {
                entitlements.dismissRefreshFailure()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss plan warning")
        }
        // Without `.contain`, an identifier on a stack is stamped onto every
        // element inside it: Retry and dismiss both became
        // "entitlementRefreshFailure", and Retry's own identifier was lost.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entitlementRefreshFailure")
        // A short drop, not its whole height: it belongs to the plan it sits
        // above, and should not seem to fall in from the section before.
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    /// "As of 9:14. Couldn't check your plan for changes."
    static func sentence(lastCheckedAt: Date?, now: Date = .now) -> String {
        guard let lastCheckedAt else { return "Couldn't check your plan yet." }
        let when = Calendar.current.isDate(lastCheckedAt, inSameDayAs: now)
            ? lastCheckedAt.formatted(date: .omitted, time: .shortened)
            : lastCheckedAt.formatted(.dateTime.day().month(.abbreviated))
        return "As of \(when). Couldn't check your plan for changes."
    }
}
