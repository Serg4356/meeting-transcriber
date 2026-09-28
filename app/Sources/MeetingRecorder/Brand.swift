// Палитра TERMINUS (TERMINUS). Единственный источник цветов
// бренда в аппке — не хардкодить эти значения в других файлах.

import SwiftUI

extension Color {
    /// #241f20 — фон знака
    static let brandCharcoal = Color(red: 0x24 / 255.0,
                                     green: 0x1F / 255.0,
                                     blue: 0x20 / 255.0)
    /// #fffff5 — силуэт/светлый
    static let brandCream = Color(red: 0xFF / 255.0,
                                  green: 0xFF / 255.0,
                                  blue: 0xF5 / 255.0)
    /// #fd8420 — акцент (π, запись, волна)
    static let brandOrange = Color(red: 0xFD / 255.0,
                                   green: 0x84 / 255.0,
                                   blue: 0x20 / 255.0)
}

/// Тонкий кремовый разделитель. НЕ использовать системный Divider() на
/// брендовых поверхностях: под светлой темой системы он чёрный на угле.
struct BrandDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.brandCream.opacity(0.12))
            .frame(height: 1)
    }
}

/// Главная кнопка бренда: пилюля `fill` с тёмным текстом, без свечения
/// (оранжевый — дозированно, только на главном действии). `outlined` —
/// вариант для активной записи: тёмная пилюля с оранжевой обводкой.
struct BrandProminentButtonStyle: ButtonStyle {
    var outlined = false
    var fill: Color = .brandOrange

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .foregroundStyle(outlined ? Color.brandOrange : Color.brandCharcoal)
            .background(Capsule().fill(
                outlined ? Color.brandCharcoal : fill))
            .overlay(Capsule().strokeBorder(
                Color.brandOrange, lineWidth: outlined ? 1.5 : 0))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
