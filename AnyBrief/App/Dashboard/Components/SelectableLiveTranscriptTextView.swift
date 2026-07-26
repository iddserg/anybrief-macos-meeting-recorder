import AppKit
import SwiftUI

struct SelectableLiveTranscriptTextView: NSViewRepresentable {
    enum Rendering {
        case plain
        case markdown
    }

    let text: String
    let placeholder: String
    var rendering: Rendering = .plain
    let onUserInteractionChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = LiveTranscriptNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.interactionChanged = { isActive in
            onUserInteractionChanged(isActive)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyRenderedText(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? LiveTranscriptNSTextView else {
            return
        }

        let content = renderedContent
        guard context.coordinator.renderedSource != content.source
            || context.coordinator.renderedIsPlaceholder != content.isPlaceholder
            || context.coordinator.rendering != rendering else {
            return
        }

        let wasPinnedToBottom = scrollView.isPinnedToBottom
        applyRenderedText(to: textView, coordinator: context.coordinator)
        if wasPinnedToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserInteractionChanged: onUserInteractionChanged)
    }

    private var renderedContent: (source: String, isPlaceholder: Bool) {
        let isPlaceholder = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (isPlaceholder ? placeholder : text, isPlaceholder)
    }

    private func applyRenderedText(to textView: NSTextView, coordinator: Coordinator) {
        let content = renderedContent
        textView.textStorage?.setAttributedString(attributedText(for: content.source, isPlaceholder: content.isPlaceholder))
        coordinator.renderedSource = content.source
        coordinator.renderedIsPlaceholder = content.isPlaceholder
        coordinator.rendering = rendering
    }

    private func attributedText(for source: String, isPlaceholder: Bool) -> NSAttributedString {
        if isPlaceholder {
            return LiveTranscriptMarkdownRenderer.plainText(
                source,
                rendering: rendering,
                color: NSColor.placeholderTextColor
            )
        }

        switch rendering {
        case .plain:
            return LiveTranscriptMarkdownRenderer.plainText(source, rendering: rendering, color: NSColor.labelColor)
        case .markdown:
            return LiveTranscriptMarkdownRenderer.markdownText(source)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate weak var textView: LiveTranscriptNSTextView?
        fileprivate var renderedSource: String?
        fileprivate var renderedIsPlaceholder = false
        fileprivate var rendering: Rendering?
        let onUserInteractionChanged: (Bool) -> Void

        init(onUserInteractionChanged: @escaping (Bool) -> Void) {
            self.onUserInteractionChanged = onUserInteractionChanged
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else {
                return
            }
            onUserInteractionChanged(textView.isUserInteractionActive)
        }
    }
}

private enum LiveTranscriptMarkdownRenderer {
    static func plainText(
        _ text: String,
        rendering: SelectableLiveTranscriptTextView.Rendering,
        color: NSColor
    ) -> NSAttributedString {
        let font = rendering == .markdown
            ? NSFont.systemFont(ofSize: 13, weight: .regular)
            : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return NSAttributedString(string: text, attributes: baseAttributes(font: font, color: color))
    }

    static func markdownText(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inCodeBlock = false

        for line in markdown.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                result.append(NSAttributedString(
                    string: "\(line)\n",
                    attributes: codeBlockAttributes()
                ))
                continue
            }

            if trimmedLine.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
                continue
            }

            if appendHeading(trimmedLine, to: result) {
                continue
            }

            if appendBullet(trimmedLine, to: result) {
                continue
            }

            if appendNumberedItem(trimmedLine, to: result) {
                continue
            }

            if trimmedLine.hasPrefix("> ") {
                let body = String(trimmedLine.dropFirst(2))
                result.append(NSAttributedString(
                    string: "| ",
                    attributes: baseAttributes(color: NSColor.secondaryLabelColor)
                ))
                appendInlineMarkdown(body, to: result, attributes: baseAttributes(color: NSColor.secondaryLabelColor))
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
                continue
            }

            appendInlineMarkdown(trimmedLine, to: result, attributes: baseAttributes())
            result.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
        }

        return result
    }

    private static func appendHeading(_ line: String, to result: NSMutableAttributedString) -> Bool {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level),
              line.dropFirst(level).first == " " else {
            return false
        }

        let title = line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
        let size: CGFloat
        switch level {
        case 1:
            size = 18
        case 2:
            size = 16
        default:
            size = 14
        }

        let style = paragraphStyle(paragraphSpacing: 8, lineSpacing: 3)
        result.append(NSAttributedString(
            string: "\(title)\n",
            attributes: baseAttributes(
                font: NSFont.systemFont(ofSize: size, weight: .semibold),
                paragraphStyle: style
            )
        ))
        return true
    }

    private static func appendBullet(_ line: String, to result: NSMutableAttributedString) -> Bool {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else {
            return false
        }

        let body = String(line.dropFirst(2))
        let style = paragraphStyle(firstLineHeadIndent: 0, headIndent: 18, paragraphSpacing: 4, lineSpacing: 3)
        result.append(NSAttributedString(string: "- ", attributes: baseAttributes(paragraphStyle: style)))
        appendInlineMarkdown(body, to: result, attributes: baseAttributes(paragraphStyle: style))
        result.append(NSAttributedString(string: "\n", attributes: baseAttributes(paragraphStyle: style)))
        return true
    }

    private static func appendNumberedItem(_ line: String, to result: NSMutableAttributedString) -> Bool {
        guard let delimiterIndex = line.firstIndex(where: { $0 == "." || $0 == ")" }) else {
            return false
        }

        let prefix = line[..<delimiterIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else {
            return false
        }

        let afterDelimiter = line.index(after: delimiterIndex)
        guard afterDelimiter < line.endIndex, line[afterDelimiter] == " " else {
            return false
        }

        let marker = "\(prefix)\(line[delimiterIndex]) "
        let body = String(line[line.index(after: afterDelimiter)...])
        let style = paragraphStyle(firstLineHeadIndent: 0, headIndent: 24, paragraphSpacing: 4, lineSpacing: 3)
        result.append(NSAttributedString(string: marker, attributes: baseAttributes(paragraphStyle: style)))
        appendInlineMarkdown(body, to: result, attributes: baseAttributes(paragraphStyle: style))
        result.append(NSAttributedString(string: "\n", attributes: baseAttributes(paragraphStyle: style)))
        return true
    }

    private static func appendInlineMarkdown(
        _ markdown: String,
        to result: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        var index = markdown.startIndex
        var plainStart = index

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else {
                return
            }
            result.append(NSAttributedString(string: String(markdown[plainStart..<end]), attributes: attributes))
        }

        while index < markdown.endIndex {
            if markdown[index...].hasPrefix("**"),
               let close = markdown.range(of: "**", range: markdown.index(index, offsetBy: 2)..<markdown.endIndex) {
                flushPlain(upTo: index)
                let bodyStart = markdown.index(index, offsetBy: 2)
                let body = String(markdown[bodyStart..<close.lowerBound])
                result.append(NSAttributedString(
                    string: body,
                    attributes: replacingFont(in: attributes, with: .semibold)
                ))
                index = close.upperBound
                plainStart = index
                continue
            }

            if markdown[index] == "`",
               let close = markdown.range(of: "`", range: markdown.index(after: index)..<markdown.endIndex) {
                flushPlain(upTo: index)
                let body = String(markdown[markdown.index(after: index)..<close.lowerBound])
                result.append(NSAttributedString(string: body, attributes: inlineCodeAttributes(from: attributes)))
                index = close.upperBound
                plainStart = index
                continue
            }

            if markdown[index] == "[",
               let labelClose = markdown.range(of: "](", range: markdown.index(after: index)..<markdown.endIndex),
               let urlClose = markdown.range(of: ")", range: labelClose.upperBound..<markdown.endIndex) {
                flushPlain(upTo: index)
                let label = String(markdown[markdown.index(after: index)..<labelClose.lowerBound])
                let urlString = String(markdown[labelClose.upperBound..<urlClose.lowerBound])
                var linkAttributes = attributes
                linkAttributes[.foregroundColor] = NSColor.linkColor
                linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let url = URL(string: urlString) {
                    linkAttributes[.link] = url
                }
                result.append(NSAttributedString(string: label, attributes: linkAttributes))
                index = urlClose.upperBound
                plainStart = index
                continue
            }

            index = markdown.index(after: index)
        }

        flushPlain(upTo: markdown.endIndex)
    }

    private static func baseAttributes(
        font: NSFont = NSFont.systemFont(ofSize: 13, weight: .regular),
        color: NSColor = NSColor.labelColor,
        paragraphStyle: NSParagraphStyle = paragraphStyle()
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static func codeBlockAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        attributes[.backgroundColor] = NSColor.controlBackgroundColor
        return attributes
    }

    private static func inlineCodeAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var codeAttributes = attributes
        codeAttributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeAttributes[.backgroundColor] = NSColor.controlBackgroundColor
        return codeAttributes
    }

    private static func replacingFont(
        in attributes: [NSAttributedString.Key: Any],
        with weight: NSFont.Weight
    ) -> [NSAttributedString.Key: Any] {
        var updated = attributes
        let size = (attributes[.font] as? NSFont)?.pointSize ?? 13
        updated[.font] = NSFont.systemFont(ofSize: size, weight: weight)
        return updated
    }

    private static func paragraphStyle(
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        paragraphSpacing: CGFloat = 5,
        lineSpacing: CGFloat = 3
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.paragraphSpacing = paragraphSpacing
        style.lineSpacing = lineSpacing
        return style
    }
}

private final class LiveTranscriptNSTextView: NSTextView {
    var interactionChanged: ((Bool) -> Void)?

    var isUserInteractionActive: Bool {
        selectedRanges.contains { rangeValue in
            rangeValue.rangeValue.length > 0
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        interactionChanged?(isUserInteractionActive)
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        interactionChanged?(isUserInteractionActive)
        return result
    }

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        interactionChanged?(isUserInteractionActive)
    }
}

private extension NSScrollView {
    var isPinnedToBottom: Bool {
        guard let documentView else {
            return true
        }
        let visibleMaxY = contentView.bounds.maxY
        let documentMaxY = documentView.bounds.maxY
        return documentMaxY - visibleMaxY < 24
    }
}
