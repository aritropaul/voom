import SwiftUI

struct MenuBarMeetingView: View {
    let meeting: UpcomingMeeting
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue)
                    .frame(width: 3, height: 16)

                Text("\(timeString) \u{00B7} \(meeting.title)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if let url = meeting.meetingURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var statusLabel: String {
        let now = Date()
        if now >= meeting.startDate && now <= meeting.endDate { return "Now" }
        let minutes = max(1, Int(ceil(meeting.startDate.timeIntervalSince(now) / 60)))
        return "Upcoming in \(minutes) min"
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: meeting.startDate)
    }
}
