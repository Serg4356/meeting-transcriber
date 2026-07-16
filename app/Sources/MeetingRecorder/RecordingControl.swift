// Плавающая вертикальная плашка (в стиле Notion) поверх всего, включая
// полноэкранный Zoom, пока идёт запись: лого сверху, «дышащий» индикатор
// записи в центре, красная кнопка стоп снизу. Нужна потому, что в fullscreen
// строка меню (а с ней иконка аппки) прячется — иначе запись не остановить.

import AppKit
import SwiftUI

// Анимированный эквалайзер — индикатор «идёт запись».
private struct RecordingWave: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 4, height: barHeight(t, i))
                }
            }
            .frame(height: 22)
        }
    }

    private func barHeight(_ t: Double, _ i: Int) -> CGFloat {
        let v = (sin(t * 3.0 + Double(i) * 0.9) + 1) / 2  // 0..1
        return 6 + v * 14
    }
}

private struct StopButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(hover ? 0.22 : 0.13))
                    .frame(width: 34, height: 34)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Остановить запись")
    }
}

struct RecordingControlView: View {
    @ObservedObject var model: AppModel
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            AppLogo(size: 34)
            if model.isPaused {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
            } else {
                RecordingWave()
            }
            Button(action: { model.togglePause() }) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 22)
            }
            .buttonStyle(.plain)
            .help(model.isPaused ? "Продолжить" : "Пауза")
            StopButton(action: onStop)
            Text(model.isPaused ? "⏸ \(model.elapsed)" : model.elapsed)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(width: 62)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        )
        .padding(6)
    }
}

@MainActor
final class RecordingControlController {
    private var panel: NSPanel?

    func show(model: AppModel, onStop: @escaping () -> Void) {
        close()
        let hosting = NSHostingView(rootView: RecordingControlView(model: model, onStop: onStop))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 74, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // поверх всего, включая полноэкранные приложения и все Spaces
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16,
                                         y: vf.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
