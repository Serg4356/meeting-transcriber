// Лого TERMINUS — микрофон-«паук» в кольце шок-маунта с оранжевой π на чаше
// (финальная иконка). Рисуется в SwiftUI на любом
// размере; мелкие детали (пружины) на 20px пропадают деградацией — это ок.

import SwiftUI

/// Четыре пружины X-ом между капсулой и кольцом.
private struct SpiderSprings: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let inner = r.width * 0.24, outer = r.width * 0.46
        var p = Path()
        for k in 0..<4 {
            let a = (45.0 + 90.0 * Double(k)) * .pi / 180
            p.move(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
            p.addLine(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
        }
        return p
    }
}

struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        let ringD = size * 0.72
        let ringY = size * 0.46
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Color.brandCharcoal)

            // кольцо шок-маунта
            Circle()
                .strokeBorder(Color.brandCream, lineWidth: size * 0.045)
                .frame(width: ringD, height: ringD)
                .position(x: size / 2, y: ringY)

            // пружины
            SpiderSprings()
                .stroke(Color.brandCream, lineWidth: size * 0.022)
                .frame(width: ringD, height: ringD)
                .position(x: size / 2, y: ringY)

            // купол-сетка
            UnevenRoundedRectangle(
                topLeadingRadius: size * 0.14, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: size * 0.14)
                .fill(Color.brandCream)
                .frame(width: size * 0.28, height: size * 0.18)
                .position(x: size / 2, y: ringY - size * 0.115)

            // поясок держателя
            Rectangle()
                .fill(Color.brandCream)
                .frame(width: size * 0.34, height: size * 0.035)
                .position(x: size / 2, y: ringY - size * 0.008)

            // чаша
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: size * 0.13,
                bottomTrailingRadius: size * 0.13, topTrailingRadius: 0)
                .fill(Color.brandCream)
                .frame(width: size * 0.28, height: size * 0.16)
                .position(x: size / 2, y: ringY + size * 0.105)

            // π на чаше — фирменная эмблема (как у Пиркса на лбу шлема)
            Text("π")
                .font(.system(size: size * 0.13, weight: .bold, design: .serif))
                .foregroundStyle(Color.brandOrange)
                .position(x: size / 2, y: ringY + size * 0.095)

            // ножка + основание
            Rectangle()
                .fill(Color.brandCream)
                .frame(width: size * 0.045, height: size * 0.09)
                .position(x: size / 2, y: ringY + ringD / 2 + size * 0.035)
            Capsule()
                .fill(Color.brandCream)
                .frame(width: size * 0.22, height: size * 0.035)
                .position(x: size / 2, y: ringY + ringD / 2 + size * 0.09)
        }
        .frame(width: size, height: size)
    }
}
