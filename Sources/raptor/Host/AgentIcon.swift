import SwiftUI

// Original, small vector marks. No fonts, bundled images, or third-party assets.
struct AgentIcon: View {
    let app: String?

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.scaleBy(x: scale, y: scale)
            switch app?.lowercased() {
            case "pi":
                // Five rectangles form the pixel P, with a square counter.
                var p = Path()
                for rect in [CGRect(x: 4, y: 3, width: 4, height: 18),
                             CGRect(x: 8, y: 3, width: 8, height: 4),
                             CGRect(x: 16, y: 7, width: 4, height: 4),
                             CGRect(x: 8, y: 11, width: 8, height: 4),
                             CGRect(x: 12, y: 7, width: 4, height: 4)] {
                    p.addRect(rect)
                }
                context.fill(p, with: .foreground)
            case "codex", "openai":
                // Six interlocking rounded lobes form the OpenAI knot silhouette.
                context.translateBy(x: 12, y: 12)
                for _ in 0..<6 {
                    var lobe = Path()
                    lobe.move(to: CGPoint(x: 0, y: -4))
                    lobe.addLine(to: CGPoint(x: 0, y: -8))
                    lobe.addCurve(to: CGPoint(x: 8, y: -8),
                                  control1: CGPoint(x: 2, y: -12), control2: CGPoint(x: 7, y: -12))
                    lobe.addCurve(to: CGPoint(x: 8, y: -1),
                                  control1: CGPoint(x: 11, y: -6), control2: CGPoint(x: 11, y: -3))
                    lobe.addLine(to: CGPoint(x: 2, y: 2.5))
                    context.stroke(lobe, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    context.rotate(by: .degrees(60))
                }
            case "claude":
                context.translateBy(x: 12, y: 12)
                for ray in 0..<12 {
                    var p = Path()
                    p.move(to: CGPoint(x: 2, y: 0))
                    p.addLine(to: CGPoint(x: ray.isMultiple(of: 3) ? 10 : 9, y: 0))
                    context.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .square))
                    context.rotate(by: .degrees(30))
                }
            default:
                // Unknown applications remain identifiable without an image dependency.
                context.draw(Text(String(app?.prefix(1) ?? "?")).font(.system(size: 18, weight: .semibold)),
                             at: CGPoint(x: 12, y: 12))
            }
        }
    }
}
