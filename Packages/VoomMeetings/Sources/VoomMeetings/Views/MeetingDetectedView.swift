import SwiftUI
import VoomCore

public struct MeetingDetectedView: View {
    let meeting: DetectedMeeting
    let onRecord: () -> Void
    let onDismiss: () -> Void

    @State private var recordHover = false
    @State private var dismissHover = false

    public init(meeting: DetectedMeeting, onRecord: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.meeting = meeting
        self.onRecord = onRecord
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: VoomTheme.spacingMD) {
            Image(systemName: "video.fill")
                .font(.system(size: 14))
                .foregroundStyle(VoomTheme.accentGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(VoomTheme.fontHeadline())
                    .foregroundStyle(VoomTheme.textPrimary)
                    .lineLimit(1)

                Text(meeting.timeRangeString)
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
            }

            Spacer(minLength: VoomTheme.spacingSM)

            Button(action: onRecord) {
                Text("Record")
                    .font(VoomTheme.fontHeadline())
                    .foregroundStyle(.white)
                    .padding(.horizontal, VoomTheme.spacingMD)
                    .padding(.vertical, VoomTheme.spacingXS)
                    .background(
                        Capsule()
                            .fill(recordHover ? VoomTheme.accentRed.opacity(0.8) : VoomTheme.accentRed)
                    )
            }
            .buttonStyle(.plain)
            .onHover { recordHover = $0 }

            Button(action: onDismiss) {
                Text("Not Now")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(dismissHover ? VoomTheme.textPrimary : VoomTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { dismissHover = $0 }
        }
        .padding(.horizontal, VoomTheme.spacingLG)
        .padding(.vertical, VoomTheme.spacingMD)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous))
    }
}
