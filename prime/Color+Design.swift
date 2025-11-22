import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension Color {
    // Background colors
    static let primeBackground = Color(hex: "FAFAFF")  // Soft off-white with slight purple tint
    static let primeGradientTop = Color(hex: "F8F6FF")
    static let primeGradientBottom = Color(hex: "FFFFFF")
    
    // Surface colors
    static let primeSurface = Color(hex: "FFFFFF")
    static let primeCardBg = Color(hex: "FFFFFF")
    static let primeToggleBg = Color(hex: "F5F3FF")  // Light purple for toggle backgrounds
    
    // Primary colors
    static let primePrimary = Color(hex: "6B4EFF")  // Modern purple
    static let primePrimaryDark = Color(hex: "5339E0")
    static let primePrimaryLight = Color(hex: "8B73FF")
    static let primeAccent = Color(hex: "FF6B9D")  // Coral pink accent
    static let primeBlue = Color(hex: "2F80ED")    // Brand blue for chat bubbles
    
    // Text colors
    static let primePrimaryText = Color(hex: "1A1A2E")  // Deep blue-black
    static let primeSecondaryText = Color(hex: "4A4A6A")  // Muted purple-gray
    static let primeTertiaryText = Color(hex: "9E9EBE")  // Light purple-gray
    
    // Control colors
    static let primeControlBg = Color(hex: "F8F6FF")  // Light purple for controls
    static let primeControlActive = Color(hex: "6B4EFF")
    static let primeControlInactive = Color(hex: "E8E5FF")
    
    // Border and divider colors
    static let primeBorder = Color(hex: "E8E5FF")
    static let primeDivider = Color(hex: "F0EDFF")
    
    // Button colors
    static let primeButtonPrimary = Color(hex: "6B4EFF")
    static let primeButtonSecondary = Color(hex: "F5F3FF")
    static let primeButtonDanger = Color(hex: "FF5A5A")
}

