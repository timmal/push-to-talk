import SwiftUI

@MainActor
final class HUDAmplitudeModel: ObservableObject {
    @Published var bars: [Float] = Array(repeating: 0, count: 24)
    static let shared = HUDAmplitudeModel()
    private var timer: Timer?
    private var target: Float = 0
    private var displayed: Float = 0
    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let alpha: Float = self.target > self.displayed ? 0.5 : 0.15
                self.displayed += (self.target - self.displayed) * alpha
                self.bars.removeFirst()
                self.bars.append(self.displayed)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func push(_ amp: Float) {
        let db = 20 * log10(max(amp, 1e-6))
        let norm = (db + 55) / 32
        target = min(1, max(0, norm))
    }
}

struct HUDPillView: View {
    @ObservedObject private var model = HUDAmplitudeModel.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.85)
                .overlay(Circle().stroke(.red.opacity(0.25), lineWidth: 4))
            HStack(spacing: 2) {
                ForEach(0..<model.bars.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(width: 3, height: CGFloat(max(2, model.bars[i] * 18)))
                        .foregroundColor(.white)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.black)
        )
    }
}
