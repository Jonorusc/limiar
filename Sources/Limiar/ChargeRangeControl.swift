import LimiarCore
import SwiftUI

/// One track, two handles: where charging stops (green, like the MagSafe LED while holding)
/// and where it resumes (orange, like the LED while charging). The current level shows behind.
struct ChargeRangeControl: View {
    let level: Int
    let limit: Int
    let resumeAt: Int
    var isEnabled = true
    /// Called once when a drag (or accessibility adjustment) ends.
    let onCommit: (_ limit: Int, _ resumeAt: Int) -> Void

    @State private var draftLimit: Int?
    @State private var draftResume: Int?

    private static let trackSpace = "chargeRangeTrack"
    private let domain = Settings.minimumResume...100
    private let trackHeight: CGFloat = 26
    private let thumbSize: CGFloat = 22

    private var shownLimit: Int { draftLimit ?? limit }
    private var shownResume: Int { draftResume ?? resumeAt }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                valueLabel(String(localized: "Stops at"), shownLimit, color: .green)
                Spacer()
                valueLabel(String(localized: "Resumes at"), shownResume, color: .orange, trailing: true)
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    // Current battery level.
                    Capsule()
                        .fill(.primary.opacity(0.14))
                        .frame(width: max(trackHeight, x(for: level, in: width) + thumbSize / 2))
                    // Band where Limiar keeps the battery.
                    Capsule()
                        .fill(LinearGradient(colors: [.orange.opacity(0.55), .green.opacity(0.7)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(thumbSize, x(for: shownLimit, in: width) - x(for: shownResume, in: width) + thumbSize),
                               height: trackHeight - 8)
                        .offset(x: x(for: shownResume, in: width) - thumbSize / 2)

                    thumb(color: .orange, value: shownResume, in: width,
                          label: String(localized: "Resume charging at"),
                          range: Settings.resumeRange(forLimit: shownLimit),
                          set: { draftResume = $0 })
                    thumb(color: .green, value: shownLimit, in: width,
                          label: String(localized: "Stop charging at"),
                          range: max(Settings.limitRange.lowerBound, shownResume + 1)...Settings.limitRange.upperBound,
                          set: { draftLimit = $0 })
                }
                .frame(height: trackHeight)
                .coordinateSpace(.named(Self.trackSpace))
            }
            .frame(height: trackHeight)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .onChange(of: limit) { draftLimit = nil }
        .onChange(of: resumeAt) { draftResume = nil }
    }

    // MARK: Pieces

    private func valueLabel(_ title: String, _ value: Int, color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)%")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
        }
    }

    private func thumb(color: Color, value: Int, in width: CGFloat, label: String,
                       range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().fill(color).padding(6))
            .frame(width: thumbSize, height: thumbSize)
            .glassEffect(.regular.interactive(), in: .circle)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .offset(x: x(for: value, in: width) - thumbSize / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
                    .onChanged { drag in
                        set(self.value(at: drag.location.x, in: width).clamped(to: range))
                    }
                    .onEnded { _ in commit() }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text("\(value)%"))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1 : -1
                set((value + step).clamped(to: range))
                commit()
            }
    }

    // MARK: Geometry

    private func x(for value: Int, in width: CGFloat) -> CGFloat {
        let usable = width - thumbSize
        let fraction = CGFloat(value - domain.lowerBound) / CGFloat(domain.upperBound - domain.lowerBound)
        return thumbSize / 2 + usable * min(1, max(0, fraction))
    }

    private func value(at x: CGFloat, in width: CGFloat) -> Int {
        let usable = max(1, width - thumbSize)
        let fraction = (x - thumbSize / 2) / usable
        return domain.lowerBound + Int((fraction * CGFloat(domain.upperBound - domain.lowerBound)).rounded())
    }

    private func commit() {
        let newLimit = shownLimit, newResume = shownResume
        guard newLimit != limit || newResume != resumeAt else {
            draftLimit = nil
            draftResume = nil
            return
        }
        onCommit(newLimit, newResume)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
