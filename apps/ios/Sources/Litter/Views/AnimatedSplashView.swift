import SwiftUI

// MARK: - Animated splash screen with bobbing, blinking, meowing kittens
//
// All animation is time-driven via TimelineView + elapsed seconds.
// No withAnimation — Canvas can't interpolate, so we compute every
// value from a clock.

struct AnimatedSplashView: View {
    @State private var startDate = Date.now

    let appReady: Bool
    var compact: Bool = false
    let onFinished: () -> Void

    // 30 Hz is plenty for this animation — the fastest thing in it is a
    // ~150ms blink, easily resolved at 30fps. `TimelineView(.animation)`
    // would otherwise tick at display refresh rate (120Hz on ProMotion),
    // redrawing every kitten 4× more often than necessary. For the inline
    // home-dashboard logo (always visible), that was ~200ms of main-thread
    // CPU per minute just on kitten drawing.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    // Palette cached once at file scope: every draw pass used to re-init
    // ~12 Color structs per frame. At 120Hz that's several thousand Color
    // allocations per second across all kittens.
    private enum Palette {
        static let leftGray     = Color(red: 0.898, green: 0.906, blue: 0.922)
        static let leftInk      = Color(red: 0.122, green: 0.161, blue: 0.216)
        static let leftWhisker  = Color(red: 0.753, green: 0.769, blue: 0.792)
        static let rightCharcoal = Color(red: 0.216, green: 0.255, blue: 0.318)
        static let rightWhite   = Color(red: 0.976, green: 0.984, blue: 0.988)
        static let rightWhisker = Color(red: 0.294, green: 0.333, blue: 0.388)
        static let ginger       = Color(red: 0.961, green: 0.620, blue: 0.043)
        static let gingerInk    = Color(red: 0.122, green: 0.161, blue: 0.216)
        static let gingerWhisker = Color(red: 0.784, green: 0.525, blue: 0.055)
        static let box          = Color(red: 0.851, green: 0.541, blue: 0.325)
        static let boxLip       = Color(red: 0.761, green: 0.478, blue: 0.271)
        static let boxHandle    = Color(red: 0.690, green: 0.396, blue: 0.208)
        static let pawDark      = Color(red: 0.294, green: 0.333, blue: 0.388)
    }

    var body: some View {
        ZStack {
            if !compact {
                LitterTheme.backgroundGradient.ignoresSafeArea()
            }

            TimelineView(.periodic(from: startDate, by: Self.frameInterval)) { timeline in
                let t = timeline.date.timeIntervalSince(startDate)

                Canvas { context, size in
                    let factor: CGFloat = compact ? 1.0 : 0.55
                    let s = min(size.width, size.height) * factor
                    let scale = s / 500
                    let ox = (size.width - s) / 2
                    let oy = compact ? (size.height - s) / 2 : (size.height - s) / 2 - size.height * 0.05
                    let anim = KittenAnimState(t: t, amplified: compact)

                    drawLeftKitten(context: context, scale: scale, ox: ox, oy: oy, anim: anim)
                    drawRightKitten(context: context, scale: scale, ox: ox, oy: oy, anim: anim)
                    drawCenterKitten(context: context, scale: scale, ox: ox, oy: oy, anim: anim)
                    drawBox(context: context, scale: scale, ox: ox, oy: oy)
                    drawPaws(context: context, scale: scale, ox: ox, oy: oy)
                }
            }

            if !compact {
                VStack {
                    Spacer()
                    Text("codex on your phone")
                        .litterMonoFont(size: 14, weight: .regular)
                        .foregroundColor(LitterTheme.textMuted)
                        .padding(.bottom, 80)
                }
            }
        }
        .onAppear { startDate = .now }
    }

    // MARK: - All animation state computed from elapsed time

    private struct KittenAnimState {
        // Bobs (sinusoidal, different periods/phases)
        let bobLeft: CGFloat
        let bobCenter: CGFloat
        let bobRight: CGFloat
        // Eye scales (1=open, ~0=blink)
        let eyeLeft: CGFloat
        let eyeRight: CGFloat
        // Ear angles in degrees
        let earLeft: CGFloat
        let earRight: CGFloat
        // Meow 0…1
        let meow: CGFloat
        // Bob amplitude multiplier (larger for compact/inline logos)
        let bobScale: CGFloat

        init(t: TimeInterval, amplified: Bool = false) {
            if amplified {
                // Faster, more visible animation for small inline logos
                bobLeft   = CGFloat(sin(t * 1.8) * 0.5 + 0.5)
                bobCenter = CGFloat(sin(t * 1.5 + 0.8) * 0.5 + 0.5)
                bobRight  = CGFloat(sin(t * 2.0 + 1.6) * 0.5 + 0.5)
                eyeLeft  = KittenAnimState.blinkPulse(t: t, period: 2.2, offset: 0.0)
                eyeRight = KittenAnimState.blinkPulse(t: t, period: 2.8, offset: 1.0)
                earLeft  = KittenAnimState.earTwitchPulse(t: t, period: 3.0, offset: 0.5, degrees: -15)
                earRight = KittenAnimState.earTwitchPulse(t: t, period: 3.5, offset: 1.5, degrees: 15)
                meow = KittenAnimState.meowPulse(t: t, period: 3.0, offset: 1.0)
                bobScale = 2.0
            } else {
                // Standard splash animation
                bobLeft   = CGFloat(sin(t * 1.4) * 0.5 + 0.5)
                bobCenter = CGFloat(sin(t * 1.2 + 0.8) * 0.5 + 0.5)
                bobRight  = CGFloat(sin(t * 1.65 + 1.6) * 0.5 + 0.5)
                eyeLeft  = KittenAnimState.blinkPulse(t: t, period: 2.8, offset: 0.0)
                eyeRight = KittenAnimState.blinkPulse(t: t, period: 3.5, offset: 1.2)
                earLeft  = KittenAnimState.earTwitchPulse(t: t, period: 4.5, offset: 0.5, degrees: -10)
                earRight = KittenAnimState.earTwitchPulse(t: t, period: 5.5, offset: 2.0, degrees: 10)
                meow = KittenAnimState.meowPulse(t: t, period: 4.0, offset: 1.5)
                bobScale = 1.0
            }
        }

        // Returns 1 normally, drops to ~0 briefly once per period
        private static func blinkPulse(t: TimeInterval, period: Double, offset: Double) -> CGFloat {
            let phase = (t + offset).truncatingRemainder(dividingBy: period)
            // Blink lasts ~0.15s
            if phase < 0.15 {
                // Quick close-open: triangle pulse
                let half: Double = 0.075
                let d = phase < half ? phase / half : (0.15 - phase) / half
                return CGFloat(1.0 - d * 0.95) // goes to 0.05
            }
            return 1
        }

        // Returns 0 normally, spikes to `degrees` briefly once per period
        private static func earTwitchPulse(t: TimeInterval, period: Double, offset: Double, degrees: CGFloat) -> CGFloat {
            let phase = (t + offset).truncatingRemainder(dividingBy: period)
            if phase < 0.25 {
                // Quick spike with bounce-back
                let norm = phase / 0.25
                // ease-out then spring back
                let curve = norm < 0.4 ? (norm / 0.4) : max(0, 1.0 - (norm - 0.4) / 0.6)
                return degrees * CGFloat(curve)
            }
            return 0
        }

        // Returns 0 normally, rises to 1 for ~0.5s once per period
        private static func meowPulse(t: TimeInterval, period: Double, offset: Double) -> CGFloat {
            let phase = (t + offset).truncatingRemainder(dividingBy: period)
            let duration: Double = 0.5
            let fadeIn: Double = 0.1
            let fadeOut: Double = 0.1
            if phase < duration {
                if phase < fadeIn {
                    return CGFloat(phase / fadeIn)
                } else if phase > duration - fadeOut {
                    return CGFloat((duration - phase) / fadeOut)
                }
                return 1
            }
            return 0
        }
    }

    // MARK: - Path helpers

    private func tri(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> Path {
        var p = Path(); p.move(to: p1); p.addLine(to: p2); p.addLine(to: p3); p.closeSubpath(); return p
    }

    private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }

    private func pt(_ x: CGFloat, _ y: CGFloat, s: CGFloat, ox: CGFloat, oy: CGFloat) -> CGPoint {
        CGPoint(x: ox + x * s, y: oy + y * s)
    }

    // MARK: - Left Kitten (Gray #E5E7EB)

    private func drawLeftKitten(context: GraphicsContext, scale: CGFloat, ox: CGFloat, oy: CGFloat, anim: KittenAnimState) {
        let gray = Palette.leftGray
        let ink  = Palette.leftInk
        let wc   = Palette.leftWhisker
        let bobY = -5 * scale * anim.bobLeft * anim.bobScale
        let s = scale

        var ctx = context
        ctx.translateBy(x: 0, y: bobY)

        // Left ear with twitch
        let pivot = pt(140, 200, s: s, ox: ox, oy: oy)
        var earCtx = ctx
        earCtx.translateBy(x: pivot.x, y: pivot.y)
        earCtx.rotate(by: .degrees(Double(anim.earLeft)))
        earCtx.translateBy(x: -pivot.x, y: -pivot.y)
        earCtx.fill(tri(pt(125,200,s:s,ox:ox,oy:oy), pt(120,150,s:s,ox:ox,oy:oy), pt(150,180,s:s,ox:ox,oy:oy)), with: .color(gray))

        // Right ear
        ctx.fill(tri(pt(199,200,s:s,ox:ox,oy:oy), pt(204,150,s:s,ox:ox,oy:oy), pt(174,180,s:s,ox:ox,oy:oy)), with: .color(gray))

        // Body
        ctx.fill(RoundedRectangle(cornerRadius: 42*s).path(in: CGRect(x: ox+120*s, y: oy+170*s, width: 84*s, height: 100*s)), with: .color(gray))

        // Eyes
        let er = 4 * s * anim.eyeLeft
        let eh = max(er * 2, 0.5)
        ctx.fill(Ellipse().path(in: CGRect(x: ox+145*s-er, y: oy+210*s-er, width: er*2, height: eh)), with: .color(ink))
        ctx.fill(Ellipse().path(in: CGRect(x: ox+179*s-er, y: oy+210*s-er, width: er*2, height: eh)), with: .color(ink))

        // Nose
        ctx.fill(tri(pt(158,220,s:s,ox:ox,oy:oy), pt(166,220,s:s,ox:ox,oy:oy), pt(162,225,s:s,ox:ox,oy:oy)), with: .color(ink))

        // Whiskers
        let ww: CGFloat = 1.2 * s
        for (x1,y1,x2,y2) in [(120,216,144,220),(118,222,143,223),(180,220,204,216),(181,223,206,222)] as [(CGFloat,CGFloat,CGFloat,CGFloat)] {
            ctx.stroke(line(pt(x1,y1,s:s,ox:ox,oy:oy), pt(x2,y2,s:s,ox:ox,oy:oy)), with: .color(wc), lineWidth: ww)
        }
    }

    // MARK: - Right Kitten (Charcoal #374151)

    private func drawRightKitten(context: GraphicsContext, scale: CGFloat, ox: CGFloat, oy: CGFloat, anim: KittenAnimState) {
        let ch  = Palette.rightCharcoal
        let wht = Palette.rightWhite
        let wc  = Palette.rightWhisker
        let bobY = -4 * scale * anim.bobRight * anim.bobScale
        let s = scale

        var ctx = context
        ctx.translateBy(x: 0, y: bobY)

        // Left ear
        ctx.fill(tri(pt(301,200,s:s,ox:ox,oy:oy), pt(296,150,s:s,ox:ox,oy:oy), pt(326,180,s:s,ox:ox,oy:oy)), with: .color(ch))

        // Right ear with twitch
        let pivot = pt(360, 200, s: s, ox: ox, oy: oy)
        var earCtx = ctx
        earCtx.translateBy(x: pivot.x, y: pivot.y)
        earCtx.rotate(by: .degrees(Double(anim.earRight)))
        earCtx.translateBy(x: -pivot.x, y: -pivot.y)
        earCtx.fill(tri(pt(375,200,s:s,ox:ox,oy:oy), pt(380,150,s:s,ox:ox,oy:oy), pt(350,180,s:s,ox:ox,oy:oy)), with: .color(ch))

        // Body
        ctx.fill(RoundedRectangle(cornerRadius: 42*s).path(in: CGRect(x: ox+296*s, y: oy+170*s, width: 84*s, height: 100*s)), with: .color(ch))

        // Eyes
        let er = 4 * s * anim.eyeRight
        let eh = max(er * 2, 0.5)
        ctx.fill(Ellipse().path(in: CGRect(x: ox+321*s-er, y: oy+210*s-er, width: er*2, height: eh)), with: .color(wht))
        ctx.fill(Ellipse().path(in: CGRect(x: ox+355*s-er, y: oy+210*s-er, width: er*2, height: eh)), with: .color(wht))

        // Nose
        ctx.fill(tri(pt(334,220,s:s,ox:ox,oy:oy), pt(342,220,s:s,ox:ox,oy:oy), pt(338,225,s:s,ox:ox,oy:oy)), with: .color(wht))

        // Whiskers
        let ww: CGFloat = 1.2 * s
        for (x1,y1,x2,y2) in [(296,216,320,220),(294,222,319,223),(356,220,380,216),(357,223,382,222)] as [(CGFloat,CGFloat,CGFloat,CGFloat)] {
            ctx.stroke(line(pt(x1,y1,s:s,ox:ox,oy:oy), pt(x2,y2,s:s,ox:ox,oy:oy)), with: .color(wc), lineWidth: ww)
        }
    }

    // MARK: - Center Kitten (Ginger #F59E0B)

    private func drawCenterKitten(context: GraphicsContext, scale: CGFloat, ox: CGFloat, oy: CGFloat, anim: KittenAnimState) {
        let ginger = Palette.ginger
        let ink    = Palette.gingerInk
        let wc     = Palette.gingerWhisker
        let bobY = -7 * scale * anim.bobCenter * anim.bobScale
        let s = scale
        let m = anim.meow

        var ctx = context
        ctx.translateBy(x: 0, y: bobY)

        // Ears
        ctx.fill(tri(pt(205,160,s:s,ox:ox,oy:oy), pt(200,105,s:s,ox:ox,oy:oy), pt(240,140,s:s,ox:ox,oy:oy)), with: .color(ginger))
        ctx.fill(tri(pt(295,160,s:s,ox:ox,oy:oy), pt(300,105,s:s,ox:ox,oy:oy), pt(260,140,s:s,ox:ox,oy:oy)), with: .color(ginger))

        // Body
        ctx.fill(RoundedRectangle(cornerRadius: 55*s).path(in: CGRect(x: ox+195*s, y: oy+130*s, width: 110*s, height: 150*s)), with: .color(ginger))

        // Happy squint arcs (visible when not meowing)
        if m < 0.99 {
            let sw = 3 * s
            var le = Path()
            le.move(to: pt(222,185,s:s,ox:ox,oy:oy))
            le.addQuadCurve(to: pt(238,185,s:s,ox:ox,oy:oy), control: pt(230,176,s:s,ox:ox,oy:oy))
            var re = Path()
            re.move(to: pt(262,185,s:s,ox:ox,oy:oy))
            re.addQuadCurve(to: pt(278,185,s:s,ox:ox,oy:oy), control: pt(270,176,s:s,ox:ox,oy:oy))
            ctx.opacity = Double(1 - m)
            ctx.stroke(le, with: .color(ink), style: StrokeStyle(lineWidth: sw, lineCap: .round))
            ctx.stroke(re, with: .color(ink), style: StrokeStyle(lineWidth: sw, lineCap: .round))
            ctx.opacity = 1
        }

        // Open round eyes (visible when meowing)
        if m > 0.01 {
            let er = 5 * s
            ctx.opacity = Double(m)
            ctx.fill(Circle().path(in: CGRect(x: ox+230*s-er, y: oy+180*s-er, width: er*2, height: er*2)), with: .color(ink))
            ctx.fill(Circle().path(in: CGRect(x: ox+270*s-er, y: oy+180*s-er, width: er*2, height: er*2)), with: .color(ink))
            ctx.opacity = 1
        }

        // Whiskers
        let ww: CGFloat = 1.2 * s
        for (x1,y1,x2,y2) in [(195,195,228,200),(193,203,227,204),(272,200,305,195),(273,204,307,203)] as [(CGFloat,CGFloat,CGFloat,CGFloat)] {
            ctx.stroke(line(pt(x1,y1,s:s,ox:ox,oy:oy), pt(x2,y2,s:s,ox:ox,oy:oy)), with: .color(wc), lineWidth: ww)
        }

        // Nose (lifts during meow)
        let nu = -3 * s * m
        ctx.fill(tri(
            CGPoint(x: ox+246*s, y: oy+198*s+nu),
            CGPoint(x: ox+254*s, y: oy+198*s+nu),
            CGPoint(x: ox+250*s, y: oy+204*s+nu)
        ), with: .color(ink))

        // Mouth
        if m > 0.01 {
            let rx = 4 * s * m
            let ry = 6 * s * m
            ctx.fill(Ellipse().path(in: CGRect(x: ox+250*s-rx, y: oy+206*s, width: rx*2, height: ry*2)), with: .color(ink))
        }
    }

    // MARK: - Box

    private func drawBox(context: GraphicsContext, scale: CGFloat, ox: CGFloat, oy: CGFloat) {
        let s = scale
        let boxColor    = Palette.box
        let lipColor    = Palette.boxLip
        let handleColor = Palette.boxHandle

        var bp = Path()
        bp.move(to: pt(100,256,s:s,ox:ox,oy:oy))
        bp.addLine(to: pt(400,256,s:s,ox:ox,oy:oy))
        bp.addLine(to: pt(385,360,s:s,ox:ox,oy:oy))
        bp.addQuadCurve(to: pt(372,370,s:s,ox:ox,oy:oy), control: pt(383,366,s:s,ox:ox,oy:oy))
        bp.addLine(to: pt(128,370,s:s,ox:ox,oy:oy))
        bp.addQuadCurve(to: pt(115,360,s:s,ox:ox,oy:oy), control: pt(117,366,s:s,ox:ox,oy:oy))
        bp.closeSubpath()
        context.fill(bp, with: .color(boxColor))

        context.fill(RoundedRectangle(cornerRadius: 8*s).path(in: CGRect(x:ox+220*s,y:oy+285*s,width:60*s,height:16*s)), with: .color(handleColor.opacity(0.8)))

        var sp = Path()
        sp.addLines([pt(100,256,s:s,ox:ox,oy:oy), pt(400,256,s:s,ox:ox,oy:oy), pt(397,268,s:s,ox:ox,oy:oy), pt(103,268,s:s,ox:ox,oy:oy)])
        sp.closeSubpath()
        context.fill(sp, with: .color(handleColor.opacity(0.4)))

        context.fill(RoundedRectangle(cornerRadius: 8*s).path(in: CGRect(x:ox+90*s,y:oy+240*s,width:320*s,height:16*s)), with: .color(lipColor))
    }

    // MARK: - Paws

    private func drawPaws(context: GraphicsContext, scale: CGFloat, ox: CGFloat, oy: CGFloat) {
        let s = scale
        let white = Color.white
        let dark  = Palette.pawDark

        for x in [135.0, 165.0] {
            context.fill(RoundedRectangle(cornerRadius: 9*s).path(in: CGRect(x:ox+x*s,y:oy+234*s,width:18*s,height:28*s)), with: .color(white))
        }
        for x in [225.0, 255.0] {
            context.fill(RoundedRectangle(cornerRadius: 10*s).path(in: CGRect(x:ox+x*s,y:oy+230*s,width:20*s,height:30*s)), with: .color(white))
        }
        for x in [317.0, 347.0] {
            context.fill(RoundedRectangle(cornerRadius: 9*s).path(in: CGRect(x:ox+x*s,y:oy+234*s,width:18*s,height:28*s)), with: .color(dark))
        }
    }
}
