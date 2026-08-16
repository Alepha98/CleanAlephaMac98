import SwiftUI

/// Custom 24px optical set (TZ-01 §4.6). Line 1.5, round caps, cold metal stroke.
/// Color comes from `foregroundStyle` — night is the same marks on plum, not invert.
enum Glyph: Equatable, Sendable {
    case smart, junk, mail, trash, leftovers, large, duplicates, browsers, dev, messengers, space, tools
    case pulse, protect, startup
    case film, archive, pdf, photo, paint
    case lock, check, warn, selectOn, selectOff, sun, moon, dayNight

    init(module: Module) {
        switch module {
        case .smart: self = .smart
        case .junk: self = .junk
        case .mail: self = .mail
        case .trash: self = .trash
        case .leftovers: self = .leftovers
        case .large: self = .large
        case .duplicates: self = .duplicates
        case .browsers: self = .browsers
        case .dev: self = .dev
        case .messengers: self = .messengers
        case .privacy: self = .lock
        case .pulse: self = .pulse
        case .protect: self = .protect
        case .startup: self = .startup
        case .space: self = .space
        case .tools: self = .tools
        }
    }

    init(item: JunkItem) {
        guard item.module == .large else {
            self = Glyph(module: item.module)
            return
        }
        switch item.url.pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "m4v", "avi": self = .film
        case "zip", "dmg", "iso", "gz", "rar", "7z": self = .archive
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "heic", "webp": self = .photo
        case "psd", "ai", "sketch": self = .paint
        default: self = .large
        }
    }
}

struct CamIcon: View {
    var glyph: Glyph
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, canvas in
            let rect = CGRect(origin: .zero, size: canvas)
            let line = max(1.15, min(rect.width, rect.height) * 1.5 / 24)
            GlyphDraw.draw(glyph, in: rect, ctx: &ctx, line: line)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum GlyphDraw {
    static func draw(_ glyph: Glyph, in rect: CGRect, ctx: inout GraphicsContext, line: CGFloat) {
        let stroke = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
        }
        func sc(_ v: CGFloat) -> CGFloat { v / 24 * min(rect.width, rect.height) }
        func strokePath(_ build: (inout Path) -> Void) {
            var p = Path()
            build(&p)
            ctx.stroke(p, with: .foreground, style: stroke)
        }
        func fillPath(_ build: (inout Path) -> Void) {
            var p = Path()
            build(&p)
            ctx.fill(p, with: .foreground)
        }
        func round(_ p: inout Path, _ rect: CGRect, radius r: CGFloat) {
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r), style: .continuous)
        }

        switch glyph {
        case .smart:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12.2), radius: sc(7.1)))
            }
            strokePath { p in
                p.move(to: pt(6.4, 14.6))
                p.addLine(to: pt(17.6, 14.6))
            }
            strokePath { p in
                p.move(to: pt(12, 2.8)); p.addLine(to: pt(12, 4.8))
                p.move(to: pt(12, 19.2)); p.addLine(to: pt(12, 21.2))
                p.move(to: pt(2.8, 12)); p.addLine(to: pt(4.8, 12))
                p.move(to: pt(19.2, 12)); p.addLine(to: pt(21.2, 12))
            }

        case .junk:
            strokePath { p in
                round(&p, CGRect(pt(5, 14.2), pt(19, 19.2)), radius: sc(1.4))
            }
            strokePath { p in
                round(&p, CGRect(pt(6.6, 9.8), pt(17.4, 14.6)), radius: sc(1.4))
            }
            strokePath { p in
                round(&p, CGRect(pt(8.2, 5.4), pt(15.8, 10.2)), radius: sc(1.4))
            }

        case .mail:
            strokePath { p in
                round(&p, CGRect(pt(4.5, 7.8), pt(19.5, 18.2)), radius: sc(1.8))
            }
            strokePath { p in
                p.move(to: pt(4.8, 8.4))
                p.addLine(to: pt(12, 13.6))
                p.addLine(to: pt(19.2, 8.4))
            }

        case .trash:
            strokePath { p in
                p.move(to: pt(6.2, 8.4))
                p.addLine(to: pt(17.8, 8.4))
            }
            strokePath { p in
                p.addArc(center: pt(12, 8.4), radius: sc(2.3), startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            }
            strokePath { p in
                p.move(to: pt(7.6, 8.4))
                p.addLine(to: pt(8.2, 18.6))
                p.addQuadCurve(to: pt(15.8, 18.6), control: pt(12, 20.2))
                p.addLine(to: pt(16.4, 8.4))
            }
            strokePath { p in
                p.move(to: pt(10.4, 11)); p.addLine(to: pt(10.6, 16.2))
                p.move(to: pt(13.4, 11)); p.addLine(to: pt(13.6, 16.2))
            }

        case .leftovers:
            strokePath { p in
                round(&p, CGRect(pt(4.2, 4.2), pt(14.8, 14.8)), radius: sc(2.4))
            }
            ctx.stroke(
                {
                    var p = Path()
                    round(&p, CGRect(pt(9.2, 9.2), pt(19.8, 19.8)), radius: sc(2.4))
                    return p
                }(),
                with: .foreground,
                style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round, dash: [sc(2.1), sc(1.7)])
            )

        case .duplicates:
            strokePath { p in
                round(&p, CGRect(pt(5.2, 5.2), pt(15.6, 17.8)), radius: sc(1.6))
            }
            strokePath { p in
                round(&p, CGRect(pt(8.4, 6.8), pt(18.8, 19.4)), radius: sc(1.6))
            }

        case .large, .pdf:
            strokePath { p in
                p.move(to: pt(8.2, 4.6))
                p.addLine(to: pt(14.2, 4.6))
                p.addLine(to: pt(18.2, 8.6))
                p.addLine(to: pt(18.2, 19.4))
                p.addQuadCurve(to: pt(16.4, 20.6), control: pt(18.2, 20.6))
                p.addLine(to: pt(7.6, 20.6))
                p.addQuadCurve(to: pt(6.2, 19.2), control: pt(6.2, 20.6))
                p.addLine(to: pt(6.2, 6.4))
                p.addQuadCurve(to: pt(8.2, 4.6), control: pt(6.2, 4.6))
            }
            strokePath { p in
                p.move(to: pt(14.2, 4.6))
                p.addLine(to: pt(14.2, 8.8))
                p.addLine(to: pt(18.2, 8.6))
            }
            if glyph == .pdf {
                strokePath { p in
                    p.move(to: pt(9, 12.2)); p.addLine(to: pt(15.2, 12.2))
                    p.move(to: pt(9, 14.8)); p.addLine(to: pt(14.2, 14.8))
                    p.move(to: pt(9, 17.2)); p.addLine(to: pt(13, 17.2))
                }
            }

        case .browsers:
            strokePath { p in
                round(&p, CGRect(pt(4.6, 5.2), pt(16.8, 15.4)), radius: sc(2))
            }
            strokePath { p in
                round(&p, CGRect(pt(7.4, 8.6), pt(19.6, 19.2)), radius: sc(2))
            }
            strokePath { p in
                p.move(to: pt(7.4, 11.4))
                p.addLine(to: pt(19.6, 11.4))
            }
            fillPath { p in
                p.addEllipse(in: CGRect(center: pt(10, 10), radius: sc(0.85)))
            }

        case .dev:
            strokePath { p in
                p.move(to: pt(9.2, 6.2))
                p.addLine(to: pt(4.8, 12))
                p.addLine(to: pt(9.2, 17.8))
            }
            strokePath { p in
                p.move(to: pt(14.8, 6.2))
                p.addLine(to: pt(19.2, 12))
                p.addLine(to: pt(14.8, 17.8))
            }
            strokePath { p in
                p.move(to: pt(11.4, 9.6))
                p.addLine(to: pt(12.6, 14.4))
            }

        case .messengers:
            strokePath { p in
                round(&p, CGRect(pt(8.4, 4.4), pt(19.6, 12.4)), radius: sc(2.6))
            }
            strokePath { p in
                round(&p, CGRect(pt(4.2, 9.6), pt(15.6, 18.2)), radius: sc(2.6))
                p.move(to: pt(6.4, 18))
                p.addLine(to: pt(5.2, 21))
                p.addLine(to: pt(9.4, 18))
            }

        case .space:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(7.6)))
            }
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(3.4)))
            }
            strokePath { p in
                p.addArc(center: pt(12, 12), radius: sc(7.6), startAngle: .degrees(-28), endAngle: .degrees(42), clockwise: false)
            }

        case .tools:
            var hex = Path()
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 6
                let q = pt(12 + 3.6 * cos(a), 8.2 + 3.6 * sin(a))
                if i == 0 { hex.move(to: q) } else { hex.addLine(to: q) }
            }
            hex.closeSubpath()
            ctx.stroke(hex, with: .foreground, style: stroke)
            strokePath { p in
                p.move(to: pt(12, 11.6))
                p.addLine(to: pt(12, 20.2))
                p.move(to: pt(10.2, 18.4))
                p.addLine(to: pt(13.8, 18.4))
            }

        case .pulse:
            strokePath { p in
                p.move(to: pt(3.4, 13.2))
                p.addLine(to: pt(6.6, 13.2))
                p.addLine(to: pt(8.4, 7.4))
                p.addLine(to: pt(11.2, 17.8))
                p.addLine(to: pt(13.6, 10.6))
                p.addLine(to: pt(16.2, 13.2))
                p.addLine(to: pt(20.6, 13.2))
            }

        case .protect:
            strokePath { p in
                p.move(to: pt(12, 3.8))
                p.addLine(to: pt(19.2, 7.2))
                p.addLine(to: pt(19.2, 13.4))
                p.addQuadCurve(to: pt(12, 20.4), control: pt(18.6, 18.6))
                p.addQuadCurve(to: pt(4.8, 13.4), control: pt(5.4, 18.6))
                p.addLine(to: pt(4.8, 7.2))
                p.closeSubpath()
            }

        case .startup:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12.4), radius: sc(7.2)))
            }
            strokePath { p in
                p.move(to: pt(12, 12.4))
                p.addLine(to: pt(12, 7.6))
                p.move(to: pt(12, 12.4))
                p.addLine(to: pt(16.4, 14.6))
            }

        case .film:
            strokePath { p in
                round(&p, CGRect(pt(4.4, 6.2), pt(19.6, 17.8)), radius: sc(1.4))
            }
            strokePath { p in
                round(&p, CGRect(pt(8.4, 8.2), pt(15.6, 15.8)), radius: sc(0.8))
            }
            strokePath { p in
                for y in [8.0, 10.6, 13.2, 15.8] as [CGFloat] {
                    p.move(to: pt(6.2, y)); p.addLine(to: pt(7.4, y))
                    p.move(to: pt(16.6, y)); p.addLine(to: pt(17.8, y))
                }
            }

        case .archive:
            strokePath { p in
                p.move(to: pt(5, 10.2))
                p.addLine(to: pt(12, 5.6))
                p.addLine(to: pt(19, 10.2))
            }
            strokePath { p in
                round(&p, CGRect(pt(5, 10.2), pt(19, 19.2)), radius: sc(1.4))
            }
            strokePath { p in
                p.move(to: pt(5, 10.2)); p.addLine(to: pt(19, 10.2))
                p.move(to: pt(12, 10.2)); p.addLine(to: pt(12, 19.2))
            }

        case .photo:
            strokePath { p in
                round(&p, CGRect(pt(4.2, 6.4), pt(19.8, 18.4)), radius: sc(2))
            }
            strokePath { p in
                p.move(to: pt(6.2, 16.6))
                p.addLine(to: pt(10.6, 10.8))
                p.addLine(to: pt(14.2, 15.2))
                p.addLine(to: pt(16.4, 13.2))
                p.addLine(to: pt(19.2, 16.6))
            }
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(16.6, 9.4), radius: sc(1.35)))
            }

        case .paint:
            strokePath { p in
                p.move(to: pt(6.4, 18.4))
                p.addLine(to: pt(13.2, 11.2))
            }
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(15.6, 8.6), radius: sc(3.1)))
            }
            strokePath { p in
                p.move(to: pt(13.4, 10.8))
                p.addQuadCurve(to: pt(16.8, 6.2), control: pt(18.6, 9.4))
            }

        case .lock:
            strokePath { p in
                round(&p, CGRect(pt(7, 11.2), pt(17, 20.2)), radius: sc(1.8))
            }
            strokePath { p in
                p.move(to: pt(9.2, 11.2))
                p.addLine(to: pt(9.2, 8.6))
                p.addArc(center: pt(12, 8.6), radius: sc(2.8), startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: pt(14.8, 11.2))
            }

        case .check:
            strokePath { p in
                p.move(to: pt(5.6, 12.2))
                p.addLine(to: pt(10.4, 17))
                p.addLine(to: pt(18.6, 7.4))
            }

        case .warn:
            strokePath { p in
                p.move(to: pt(12, 4.6))
                p.addLine(to: pt(20.4, 19.2))
                p.addLine(to: pt(3.6, 19.2))
                p.closeSubpath()
            }
            strokePath { p in
                p.move(to: pt(12, 10.2)); p.addLine(to: pt(12, 14.4))
            }
            fillPath { p in
                p.addEllipse(in: CGRect(center: pt(12, 16.6), radius: sc(0.7)))
            }

        case .selectOff:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(7.2)))
            }

        case .selectOn:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(7.2)))
            }
            fillPath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(3.6)))
            }

        case .sun:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(3.4)))
            }
            strokePath { p in
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    let c = cos(a), s = sin(a)
                    p.move(to: pt(12 + 5.4 * c, 12 + 5.4 * s))
                    p.addLine(to: pt(12 + 8.6 * c, 12 + 8.6 * s))
                }
            }

        case .moon:
            // SF-style solid crescent: outer disk minus offset disk (even-odd).
            // Centers far apart so the bite is a fat moon, not a Venn ring.
            var crescent = Path()
            crescent.addEllipse(in: CGRect(center: pt(11.0, 12.0), radius: sc(8.0)))
            crescent.addEllipse(in: CGRect(center: pt(16.2, 10.2), radius: sc(6.6)))
            ctx.fill(crescent, with: .foreground, style: FillStyle(eoFill: true))

        case .dayNight:
            strokePath { p in
                p.addEllipse(in: CGRect(center: pt(12, 12), radius: sc(7)))
            }
            fillPath { p in
                p.move(to: pt(12, 5))
                p.addArc(center: pt(12, 12), radius: sc(7), startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                p.closeSubpath()
            }
        }
    }
}

private extension CGRect {
    init(_ a: CGPoint, _ b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    init(center: CGPoint, radius: CGFloat) {
        self.init(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
