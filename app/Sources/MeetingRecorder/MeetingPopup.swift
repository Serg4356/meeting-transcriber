// Плавающее окошко-напоминание перед встречей (как всплывашка Notion).

import AppKit
import SwiftUI

struct MeetingPopupView: View {
    let meeting: Meeting
    let onJoinRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "video.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(meeting.startsInText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: onJoinRecord) {
                    Text(meeting.url != nil ? "Подключиться и записать" : "Записать")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Позже", action: onDismiss)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

@MainActor
final class MeetingPopupController {
    private var panel: NSPanel?

    func show(meeting: Meeting,
              onJoinRecord: @escaping () -> Void) {
        close()
        let view = MeetingPopupView(
            meeting: meeting,
            onJoinRecord: { [weak self] in onJoinRecord(); self?.close() },
            onDismiss: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Встреча скоро"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20,
                                         y: vf.maxY - size.height - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
