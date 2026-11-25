import SwiftUI

/// Asks, once, before anything goes to the AI.
///
/// Albus sends what a plan or a marking needs to Anthropic, which runs the AI.
/// App Review guideline 5.1.2(i) asks an app to say so inside the app and get
/// the student's permission first; the privacy policy alone does not. Asked in
/// onboarding just before the first plan, and once, as a sheet, for a student
/// who joined before it existed (`RootView`). Settings can change the answer.
///
/// Not now is a real choice: the phone still plans every task, the way it
/// does offline. Only marking needs the AI, and it asks again there.
struct AIPermissionView: View {
    @Environment(\.openURL) private var openURL

    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                AlbusCactus(size: 56, mood: .calm)
                    .accessibilityHidden(true)

                Text("Albus plans and marks with AI")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("To write your study plans and mark your work, Albus sends what each one "
                     + "needs to Anthropic, the company that runs the AI.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    point("For a plan: the task's title, type, deadline and hours, "
                          + "and your notes and rubric if you added them.")
                    point("For marking: the text of your work, its title, the rubric "
                          + "and the criteria you chose.")
                    point("Your files and photos stay on your phone. Albus reads them there.")
                }

                Button("Privacy policy") { openURL(AppLinks.privacy) }
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.top, Tokens.Spacing.xxl)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Tokens.Spacing.s) {
                PrimaryButton(title: "Allow", action: onAllow)
                Button("Not now", action: onNotNow)
                    .font(Tokens.Typography.label)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .frame(height: 44)
                Text("Without AI, Albus still plans your study sessions on your phone. "
                     + "You can change this in Settings.")
                    .font(Tokens.Typography.micro)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.l)
        }
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Tokens.Palette.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
