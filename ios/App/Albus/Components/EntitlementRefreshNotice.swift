import SwiftUI
import AlbusCore

/// A quiet warning that plan figures are stale, shared by every screen that
/// presents a plan or allowance. Retry asks the server again; dismissing only
/// hides this message and cannot change an entitlement.
struct EntitlementRefreshNotice: View {
    @Environment(EntitlementService.self) private var entitlements

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.SubjectColor.amber.color)
                .accessibilityHidden(true)

            Text("Plan figures couldn't be confirmed. Showing the last values.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry") {
                Task { await entitlements.refresh() }
            }
            .font(Tokens.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Tokens.Palette.accent)
            .buttonStyle(.plain)
            .disabled(entitlements.isLoading)
            .accessibilityIdentifier("retryEntitlementRefresh")

            Button {
                entitlements.dismissRefreshFailure()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss plan warning")
        }
        .padding(Tokens.Spacing.m)
        .background(Tokens.SubjectColor.amber.color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip,
                                         style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                .strokeBorder(Tokens.SubjectColor.amber.color.opacity(0.18), lineWidth: 0.5)
        }
        // Without `.contain`, an identifier on a stack is stamped onto every
        // element inside it: Retry and dismiss both became
        // "entitlementRefreshFailure", and Retry's own identifier was lost.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entitlementRefreshFailure")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
