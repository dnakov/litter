import SwiftUI

struct ContextBadgeView: View, Equatable {
    let percent: Int
    let tint: Color

    private let cornerRadius: CGFloat = 3.5
    private let strokeWidth: CGFloat = 1.2
    private let inset: CGFloat = 1.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(tint.opacity(0.4), lineWidth: strokeWidth)

            GeometryReader { geo in
                let inner = geo.size.width - (inset + strokeWidth) * 2
                RoundedRectangle(cornerRadius: max(0, cornerRadius - inset))
                    .fill(tint.opacity(0.25))
                    .frame(width: max(0, inner * CGFloat(percent) / 100.0))
                    .padding(.leading, inset + strokeWidth / 2)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .padding(.vertical, inset + strokeWidth / 2)

            Text("\(percent)")
                .font(LitterFont.monospaced(size: 9.5, weight: .heavy))
                .foregroundColor(tint)
        }
        .frame(width: 35, height: 16)
    }
}
