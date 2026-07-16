// Лого Meeting Transcriber — микрофон с красным record-глазком на градиенте.
// Нарисовано в SwiftUI (совпадает с app/logo.svg), рендерится на любом размере.

import SwiftUI

private struct MicStand: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        // U-держатель
        p.move(to: CGPoint(x: w * 0.22, y: h * 0.50))
        p.addCurve(to: CGPoint(x: w * 0.78, y: h * 0.50),
                   control1: CGPoint(x: w * 0.22, y: h * 0.76),
                   control2: CGPoint(x: w * 0.78, y: h * 0.76))
        // ножка
        p.move(to: CGPoint(x: w * 0.50, y: h * 0.70))
        p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.84))
        // основание
        p.move(to: CGPoint(x: w * 0.37, y: h * 0.855))
        p.addLine(to: CGPoint(x: w * 0.63, y: h * 0.855))
        return p
    }
}

struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.43, green: 0.37, blue: 0.96),
                             Color(red: 0.55, green: 0.24, blue: 0.94)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            // тело микрофона
            Capsule()
                .fill(.white)
                .frame(width: size * 0.235, height: size * 0.38)
                .position(x: size / 2, y: size * 0.41)

            // красный record-глазок
            Circle()
                .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                .frame(width: size * 0.115)
                .position(x: size / 2, y: size * 0.34)

            // держатель + ножка + основание
            MicStand()
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.047, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}
