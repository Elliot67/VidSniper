import SwiftUI

/// Curseur vertical de balance entre les deux lignes de son : en haut (+1) le son système ressort,
/// en bas (-1) la voix ressort. Un repère marque le milieu (même niveau), où le curseur s'aimante.
/// Double-clic : réglage par défaut.
struct BalanceSlider: View {
    @Binding var value: Double
    let defaultValue: Double
    let isEnabled: Bool

    private static let knobSize: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let travel = height - Self.knobSize
            let knobY = (1 - (value + 1) / 2) * travel

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Theme.border)
                    .frame(width: 4, height: height)

                Rectangle()
                    .fill(Theme.textMuted)
                    .frame(width: 10, height: 1)
                    .offset(y: height / 2 - 0.5)

                Circle()
                    .fill(isEnabled ? Theme.accent : Theme.textMuted)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(y: knobY)
            }
            .frame(width: geometry.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let position = min(max(drag.location.y - Self.knobSize / 2, 0), travel)
                        let newValue = 1 - 2 * position / max(travel, 1)
                        value = abs(newValue) < 0.06 ? 0 : newValue
                    }
            )
            .onTapGesture(count: 2) {
                value = defaultValue
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
    }
}
