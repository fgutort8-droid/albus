import SwiftUI

/// A from–until pair of whole hours, as the study windows are stored.
///
/// Until is always after from: moving from past it moves until along, so the
/// pair can never describe an empty or backwards window. 24 is midnight at the
/// end of the day.
struct HourRangePicker: View {
    @Binding var from: Int
    @Binding var until: Int

    /// The earliest a window may open, and the latest it may close.
    static let earliest = 5
    static let latest = 24

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            hourMenu("From", selection: $from, hours: Array(Self.earliest...(Self.latest - 1)))
            hourMenu("Until", selection: $until, hours: Array((from + 1)...Self.latest))
        }
        .onChange(of: from) { _, newFrom in
            // Written only when it has to move. A weekend window still
            // following the school days changes `from` without the student
            // touching it, and a write here would save it as their own.
            let adjusted = Self.until(afterMoving: newFrom, until: until)
            if adjusted != until { until = adjusted }
        }
    }

    /// Until, kept at least an hour after a moved from.
    static func until(afterMoving from: Int, until: Int) -> Int {
        max(until, min(from + 1, latest))
    }

    /// "4 PM", or "16:00" on a phone set to 24-hour time. 24 reads as midnight.
    static func label(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func hourMenu(_ title: String, selection: Binding<Int>, hours: [Int]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            Menu {
                Picker(title, selection: selection) {
                    ForEach(hours, id: \.self) { Text(Self.label($0)).tag($0) }
                }
            } label: {
                HStack {
                    Text(Self.label(selection.wrappedValue))
                        .font(Tokens.Typography.label)
                        .foregroundStyle(Tokens.Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.inkMuted)
                }
                .padding(Tokens.Spacing.m)
                .background(Tokens.Glass.fill,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }
            }
            .accessibilityLabel("\(title) \(Self.label(selection.wrappedValue))")
        }
        .frame(maxWidth: .infinity)
    }
}
