import SwiftUI
import AppKit

/// JSON 语法着色。
///
/// 只做四类 token（key / string / number / true·false·null），不做完整解析——
/// 这是展示层，输入已经是格式化好的 JSON 文本，正则足够，而且不会因为一个坏字节就整段不显示。
///
/// 有硬上限：超过 `maxStyledBytes` 的部分原样输出。不是舍不得 CPU，是
/// `Text` 渲染超长 AttributedString 本身就慢，彩色标题不值得让选中一条 3MB 的 body 卡三秒。
enum JSONHighlight {
    static let maxStyledBytes = 200_000

    private static let keyRE = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*:"#)
    private static let stringRE = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    private static let numberRE = try? NSRegularExpression(pattern: #"(?<![\w"])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
    private static let keywordRE = try? NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#)

    static func styled(_ text: String, size: CGFloat = 12) -> AttributedString {
        guard !text.isEmpty else { return AttributedString("") }

        let clipped = text.utf8.count > maxStyledBytes
        let shown = clipped ? String(text.prefix(maxStyledBytes)) + "\n\n// … 超过 \(maxStyledBytes / 1024) KB，其余部分未着色" : text

        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let out = NSMutableAttributedString(
            string: shown,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        let ns = shown as NSString
        let full = NSRange(location: 0, length: ns.length)
        let taken = NSMutableIndexSet()

        // 顺序有意义：key 先占位（它本身也是一段字符串），后面的规则跳过已占位区间
        paint(keyRE, color: .systemTeal, ns: ns, full: full, out: out, taken: taken)
        paint(stringRE, color: .systemGreen, ns: ns, full: full, out: out, taken: taken)
        paint(numberRE, color: .systemOrange, ns: ns, full: full, out: out, taken: taken)
        paint(keywordRE, color: .systemPink, ns: ns, full: full, out: out, taken: taken)

        return AttributedString(out)
    }

    private static func paint(
        _ re: NSRegularExpression?,
        color: NSColor,
        ns: NSString,
        full: NSRange,
        out: NSMutableAttributedString,
        taken: NSMutableIndexSet
    ) {
        guard let re else { return }
        re.enumerateMatches(in: ns as String, range: full) { match, _, _ in
            guard let r = match?.range, r.location != NSNotFound else { return }
            // 已被更靠前的规则占位（比如 key 里的字符串），跳过
            if taken.intersects(in: r) { return }
            taken.add(in: r)
            out.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}
