import AppKit
import SwiftUI

/// A small, bounded lexer for read-only previews; no external scripts or web
/// views execute file contents. Theme colors are resolved by AppKit on redraw.
@MainActor
enum PreviewSyntax {
    static func attributed(_ text: String, language: String?) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard language != nil else { return result }
        let pattern = #"(?m)//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:import|from|class|struct|enum|extension|func|def|let|var|const|return|if|else|switch|case|default|for|while|in|public|private|static|async|await|throws|try|catch|guard|some|nil|null|true|false|self|fn|use|pub|mut|type|interface|export|function|new)\b|\b[A-Z][A-Za-z0-9_]*\b|\b\d+(?:\.\d+)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            let color: NSColor
            if token.hasPrefix("//") || token.hasPrefix("/*") || token.hasPrefix("#") { color = .secondaryLabelColor }
            else if token.hasPrefix("\"") || token.hasPrefix("'") { color = .systemRed }
            else if token.first?.isNumber == true { color = .systemPurple }
            else if token.first?.isUppercase == true { color = .systemTeal }
            else { color = .systemPink }
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
        return result
    }
}

struct TextFilePreview: View {
    let text: String
    var language: String?
    @State private var showsLines = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language ?? "Plain text")
                Spacer()
                if language != nil { Toggle("Line numbers", isOn: $showsLines).toggleStyle(.checkbox) }
                else { Text("Soft wrap") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 36)
            Divider()
            NativePreviewText(text: text, language: language, showsLines: language != nil && showsLines).frame(height: 330)
        }
    }
}

private struct NativePreviewText: NSViewRepresentable {
    let text: String
    let language: String?
    let showsLines: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PreviewTextScrollView()
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 330))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        view.backgroundColor = .textBackgroundColor
        scroll.documentView = view; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalRulerView = PreviewLineRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.hasVerticalRuler = true
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text || context.coordinator.language != language {
            view.textStorage?.setAttributedString(PreviewSyntax.attributed(text, language: language))
            context.coordinator.language = language
        }
        scroll.rulersVisible = showsLines
        scroll.verticalRulerView?.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var language: String? }
}

private final class PreviewTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        if abs(text.frame.width - width) > 0.5 {
            text.setFrameSize(NSSize(width: width, height: max(contentSize.height, text.frame.height)))
        }
        verticalRulerView?.needsDisplay = true
    }
}

private final class PreviewLineRuler: NSRulerView {
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 38
    }
    required init(coder: NSCoder) { fatalError("Use init(scrollView:orientation:)") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text = scrollView?.documentView as? NSTextView,
              let layout = text.layoutManager, let container = text.textContainer else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        let source = text.string as NSString
        let visible = text.visibleRect
        var visibleTextRect = visible
        visibleTextRect.origin.y -= text.textContainerInset.height
        let glyphs = layout.glyphRange(forBoundingRect: visibleTextRect, in: container)
        guard glyphs.length > 0 else { return }
        let firstCharacter = layout.characterIndexForGlyph(at: glyphs.location)
        var number = source.substring(to: firstCharacter).filter { $0 == "\n" }.count + 1
        layout.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            if character == 0 || source.character(at: character - 1) == 10 {
                let value = String(number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
                let y = line.minY + text.textContainerInset.height - visible.minY
                value.draw(at: NSPoint(x: self.ruleThickness - value.size(withAttributes: attributes).width - 8, y: y), withAttributes: attributes)
                number += 1
            }
        }
    }
}

struct MarkdownFilePreview: View {
    let text: String
    @State private var source = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Markdown").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("Markdown view", selection: $source) {
                    Text("Rendered").tag(false); Text("Source").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
            }.padding(10)
            Divider()
            if source { NativePreviewText(text: text, language: nil, showsLines: false).frame(height: 330) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(MarkdownPreviewBlock.parse(text).enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 330).background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
    @ViewBuilder private func blockView(_ block: MarkdownPreviewBlock) -> some View {
        switch block.kind {
        case .heading(let level): inline(block.text).font(.system(size: level == 1 ? 22 : level == 2 ? 17 : 14, weight: .medium))
        case .quote:
            HStack { Rectangle().fill(Color.accentColor).frame(width: 2); inline(block.text).foregroundStyle(.secondary) }
        case .code: Text(block.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        case .list: HStack(alignment: .top, spacing: 8) { Text("•").foregroundStyle(.secondary); inline(block.text) }
        case .rule: Divider()
        case .paragraph: inline(block.text)
        }
    }
    private func inline(_ value: String) -> Text {
        let parsed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        return Text(parsed)
    }
}

struct MarkdownPreviewBlock: Equatable {
    enum Kind: Equatable { case heading(Int), paragraph, quote, list, code, rule }
    let kind: Kind
    let text: String
    static func parse(_ source: String) -> [Self] {
        var blocks: [Self] = [], paragraph: [String] = [], code: [String] = []
        var inCode = false
        func flush() {
            if !paragraph.isEmpty { blocks.append(.init(kind: .paragraph, text: paragraph.joined(separator: " "))); paragraph.removeAll() }
        }
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                flush()
                if inCode { blocks.append(.init(kind: .code, text: code.joined(separator: "\n"))); code.removeAll() }
                inCode.toggle(); continue
            }
            if inCode { code.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush(); blocks.append(.init(kind: .heading(hashes), text: String(line.dropFirst(hashes + 1))))
            } else if line.hasPrefix("> ") { flush(); blocks.append(.init(kind: .quote, text: String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); blocks.append(.init(kind: .list, text: String(line.dropFirst(2)))) }
            else if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) { flush(); blocks.append(.init(kind: .rule, text: "")) }
            else { paragraph.append(line) }
        }
        flush()
        if !code.isEmpty { blocks.append(.init(kind: .code, text: code.joined(separator: "\n"))) }
        return blocks
    }
}
