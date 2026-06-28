import SwiftUI

/// A short, scenic launch animation: a motorcycle riding a winding road
/// through layered mountains at golden hour. Runs for roughly one second
/// before handing off to the main app content.
struct SplashScreenView: View {
    /// Drives every animated property. Flipping this once on appear lets the
    /// individual `.animation` modifiers play their entrance in parallel.
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                // Golden-hour sky gradient.
                LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.78, blue: 0.42),
                        Color(red: 0.96, green: 0.55, blue: 0.36),
                        Color(red: 0.62, green: 0.38, blue: 0.52)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // The sun, rising into place behind the peaks.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, Color(red: 1.0, green: 0.92, blue: 0.62)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size.width * 0.22
                        )
                    )
                    .frame(width: size.width * 0.4, height: size.width * 0.4)
                    .position(x: size.width * 0.5, y: size.height * (animate ? 0.42 : 0.6))
                    .opacity(animate ? 1 : 0)
                    .animation(.easeOut(duration: 0.9), value: animate)

                // Far mountain range.
                MountainShape(peaks: 4, jaggedness: 0.55)
                    .fill(Color(red: 0.46, green: 0.34, blue: 0.5))
                    .frame(height: size.height * 0.45)
                    .position(x: size.width * 0.5, y: size.height * 0.62)
                    .offset(y: animate ? 0 : 40)
                    .opacity(animate ? 1 : 0)
                    .animation(.easeOut(duration: 0.7).delay(0.05), value: animate)

                // Near mountain range, darker for depth.
                MountainShape(peaks: 3, jaggedness: 0.75)
                    .fill(Color(red: 0.28, green: 0.2, blue: 0.34))
                    .frame(height: size.height * 0.4)
                    .position(x: size.width * 0.5, y: size.height * 0.72)
                    .offset(y: animate ? 0 : 60)
                    .opacity(animate ? 1 : 0)
                    .animation(.easeOut(duration: 0.7).delay(0.15), value: animate)

                // The road sweeping toward the horizon.
                RoadShape()
                    .fill(Color(red: 0.16, green: 0.14, blue: 0.18))
                    .frame(height: size.height * 0.4)
                    .position(x: size.width * 0.5, y: size.height * 0.85)
                    .opacity(animate ? 1 : 0)
                    .animation(.easeOut(duration: 0.5).delay(0.2), value: animate)

                // The rider, sweeping in from the left along the road.
                Image(systemName: "figure.outdoor.cycle")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white)
                    .frame(width: size.width * 0.22)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                    .position(
                        x: animate ? size.width * 0.56 : -size.width * 0.2,
                        y: size.height * 0.8
                    )
                    .opacity(animate ? 1 : 0)
                    .animation(.easeOut(duration: 0.8).delay(0.25), value: animate)

                // App title fading up at the end.
                VStack(spacing: 6) {
                    Text("MotoRoute")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    Text("Ride the open road")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .position(x: size.width * 0.5, y: size.height * 0.22)
                .opacity(animate ? 1 : 0)
                .offset(y: animate ? 0 : 12)
                .animation(.easeOut(duration: 0.6).delay(0.4), value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

/// A jagged mountain silhouette generated from a fixed pseudo-random seed so
/// the peaks look natural while staying identical on every launch.
private struct MountainShape: Shape {
    let peaks: Int
    let jaggedness: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

        let segments = max(peaks * 2, 2)
        // Deterministic heights so the silhouette is stable across launches.
        let heights: [Double] = (0...segments).map { index in
            let phase = Double(index) * (1.3 + jaggedness)
            let wave = (sin(phase) + sin(phase * 1.7)) / 2
            return 0.5 - (wave * 0.45)
        }

        for index in 0...segments {
            let x = rect.minX + rect.width * (Double(index) / Double(segments))
            let y = rect.minY + rect.height * heights[index]
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A trapezoidal road that narrows toward the horizon to give a sense of depth.
private struct RoadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topInset = rect.width * 0.42
        path.move(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    SplashScreenView()
}
