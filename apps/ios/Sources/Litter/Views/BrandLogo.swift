import SwiftUI
import UIKit

struct BrandLogo: View {
    var size: CGFloat

    private var bundledLogo: UIImage? {
        UIImage(named: "brand_logo") ?? UIImage(named: "brand_logo.png")
    }

    var body: some View {
        if let bundledLogo {
            Image(uiImage: bundledLogo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text("litter")
                .font(.system(size: size * 0.32, weight: .bold, design: .monospaced))
                .foregroundColor(LitterTheme.accent)
        }
    }
}
