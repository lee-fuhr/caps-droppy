//
//  ServiceMarks.swift
//  Capsdroppy
//
//  The Claude and OpenAI marks, drawn small and in one colour so a row can say
//  which service it is without a word. The outlines are the marks as published
//  by Simple Icons (https://simpleicons.org, CC0 for the artwork); Claude is a
//  trademark of Anthropic and OpenAI of OpenAI, used here only to name each
//  account's service. A small SVG path reader turns them into SwiftUI paths.
//

import SwiftUI

enum CapsMarkPaths {
    static let claude = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    static let openAI = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
}

/// An SVG path (24 x 24 box) as a shape that fills whatever square it is given.
struct CapsMark: Shape {
    let d: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        return CapsSVG.path(d).applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}

/// The mark for an account's service, or nothing for an account with no service.
struct CapsServiceIcon: View {
    let kind: CapsAccountKind
    var size: CGFloat = 14

    var body: some View {
        switch kind {
        case .claude: CapsMark(d: CapsMarkPaths.claude).frame(width: size, height: size)
        case .codex: CapsMark(d: CapsMarkPaths.openAI).frame(width: size, height: size)
        case .snapshot: EmptyView()
        }
    }
}

enum CapsSVG {
    /// Reads M L H V C S Q T A Z, absolute and relative. Enough for a mark.
    static func path(_ d: String) -> Path {
        var p = Path()
        let chars = Array(d)
        var i = 0
        var cmd: Character = " "
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastC: CGPoint? = nil   // last cubic control, for S
        var lastQ: CGPoint? = nil   // last quad control, for T

        func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }
        func number() -> Double? {
            skip()
            var j = i
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            var digits = false, dot = false
            while j < chars.count {
                let c = chars[j]
                if c.isNumber { digits = true; j += 1 }
                else if c == ".", !dot { dot = true; j += 1 }
                else { break }
            }
            guard digits else { return nil }
            if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                var k = j + 1
                if k < chars.count, chars[k] == "-" || chars[k] == "+" { k += 1 }
                if k < chars.count, chars[k].isNumber { while k < chars.count, chars[k].isNumber { k += 1 }; j = k }
            }
            let v = Double(String(chars[i..<j]))
            i = j
            return v
        }
        func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        while true {
            skip()
            guard i < chars.count else { break }
            if chars[i].isLetter { cmd = chars[i]; i += 1 }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            switch cmd.uppercased() {
            case "M":
                guard let x = number(), let y = number() else { return p }
                cur = CGPoint(x: base.x + x, y: base.y + y); start = cur; p.move(to: cur)
                cmd = rel ? "l" : "L"; lastC = nil; lastQ = nil
            case "L":
                guard let x = number(), let y = number() else { return p }
                cur = CGPoint(x: base.x + x, y: base.y + y); p.addLine(to: cur); lastC = nil; lastQ = nil
            case "H":
                guard let x = number() else { return p }
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y); p.addLine(to: cur); lastC = nil; lastQ = nil
            case "V":
                guard let y = number() else { return p }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); p.addLine(to: cur); lastC = nil; lastQ = nil
            case "C":
                guard let a = number(), let b = number(), let c = number(), let d = number(), let x = number(), let y = number() else { return p }
                let c1 = CGPoint(x: base.x + a, y: base.y + b), c2 = CGPoint(x: base.x + c, y: base.y + d)
                cur = CGPoint(x: base.x + x, y: base.y + y); p.addCurve(to: cur, control1: c1, control2: c2); lastC = c2; lastQ = nil
            case "S":
                guard let c = number(), let d = number(), let x = number(), let y = number() else { return p }
                let c1 = lastC.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: base.x + c, y: base.y + d)
                cur = CGPoint(x: base.x + x, y: base.y + y); p.addCurve(to: cur, control1: c1, control2: c2); lastC = c2; lastQ = nil
            case "Q":
                guard let a = number(), let b = number(), let x = number(), let y = number() else { return p }
                let q = CGPoint(x: base.x + a, y: base.y + b)
                cur = CGPoint(x: base.x + x, y: base.y + y); p.addQuadCurve(to: cur, control: q); lastQ = q; lastC = nil
            case "T":
                guard let x = number(), let y = number() else { return p }
                let q = lastQ.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                cur = CGPoint(x: base.x + x, y: base.y + y); p.addQuadCurve(to: cur, control: q); lastQ = q; lastC = nil
            case "A":
                guard let rx = number(), let ry = number(), let rot = number(), let large = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return p }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                addArc(&p, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: end)
                cur = end; lastC = nil; lastQ = nil
            case "Z":
                p.closeSubpath(); cur = start; lastC = nil; lastQ = nil
            default:
                return p
            }
        }
        return p
    }

    /// An SVG elliptical arc as cubic curves (SVG 1.1, F.6.5 and F.6.6).
    private static func addArc(_ p: inout Path, from p0: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double,
                               large: Bool, sweep: Bool, to p1: CGPoint) {
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 || (p0.x == p1.x && p0.y == p1.y) { p.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = Int(ceil(abs(delta) / (.pi / 2) - 1e-9))
        let step = delta / Double(max(1, segments))
        let t = 4.0 / 3.0 * tan(step / 4)
        var a1 = theta1
        for _ in 0..<max(1, segments) {
            let a2 = a1 + step
            func point(_ a: Double, _ dx: Double = 0, _ dy: Double = 0) -> CGPoint {
                let x = rx * cos(a) + dx, y = ry * sin(a) + dy
                return CGPoint(x: cosP * x - sinP * y + cx, y: sinP * x + cosP * y + cy)
            }
            let c1 = point(a1, -t * rx * sin(a1), t * ry * cos(a1))
            let c2 = point(a2, t * rx * sin(a2), -t * ry * cos(a2))
            p.addCurve(to: point(a2), control1: c1, control2: c2)
            a1 = a2
        }
    }
}
