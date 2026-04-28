//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//  Purpose: Adds a cleaner right-click menu with Markdown formatting actions.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    // Override context menu to redirect Bold to Markdown action
    public func textView(_ textView: NSTextView,
                  menu: NSMenu,
                  for event: NSEvent,
                  at charIndex: Int) -> NSMenu? {
        let customMenu = menu.copy() as? NSMenu ?? NSMenu()

        // Replace the default Font submenu with a custom Format menu
        if let fontIndex = customMenu.items.firstIndex(where: { $0.title == "Font" }) {
            customMenu.removeItem(at: fontIndex)
            let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            let formatSubmenu = NSMenu(title: "Format")
            // Bold item
            let boldItem = NSMenuItem(title: "Bold", action: #selector(didMarkdownBold(_:)), keyEquivalent: "")
            boldItem.target = self
            formatSubmenu.addItem(boldItem)
            // Italic item
            let italicItem = NSMenuItem(title: "Italic", action: #selector(didMarkdownItalic(_:)), keyEquivalent: "")
            italicItem.target = self
            formatSubmenu.addItem(italicItem)
            formatItem.submenu = formatSubmenu
            customMenu.insertItem(formatItem, at: fontIndex)
            // Heading top-level menu
            let headingItem = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
            let headingSubmenu = NSMenu(title: "Heading")
            
            let h1Item = NSMenuItem(title: "H1", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
            h1Item.target = self
            h1Item.tag = 1
            headingSubmenu.addItem(h1Item)
            
            let h2Item = NSMenuItem(title: "H2", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
            h2Item.target = self
            h2Item.tag = 2
            headingSubmenu.addItem(h2Item)
            
            let h3Item = NSMenuItem(title: "H3", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
            h3Item.target = self
            h3Item.tag = 3
            headingSubmenu.addItem(h3Item)
            
            headingItem.submenu = headingSubmenu
            // insert Heading menu right after Format
            customMenu.insertItem(headingItem, at: fontIndex + 1)

            // Lists top-level menu
            let listItem = NSMenuItem(title: "Lists", action: nil, keyEquivalent: "")
            let listSubmenu = NSMenu(title: "Lists")

            let unorderedItem = NSMenuItem(title: "Bullet", action: #selector(didMarkdownUnorderedList(_:)), keyEquivalent: "")
            unorderedItem.target = self
            listSubmenu.addItem(unorderedItem)

            let orderedItem = NSMenuItem(title: "Numbered", action: #selector(didMarkdownOrderedList(_:)), keyEquivalent: "")
            orderedItem.target = self
            listSubmenu.addItem(orderedItem)

            listItem.submenu = listSubmenu
            customMenu.insertItem(listItem, at: fontIndex + 2)
            customMenu.insertItem(NSMenuItem.separator(), at: fontIndex + 3)
        }

        return customMenu
    }

    /// Entfernt führende und abschließende Leerzeichen und liefert Kerntext, Start und Länge
    func trimmedCore(in nsText: NSString, range: NSRange) -> (trimmed: String, coreStart: Int, coreLength: Int) {
        let text = nsText.substring(with: range)
        let leadingWS = text.prefix { $0.isWhitespace }.count
        let trailingWS = text.reversed().prefix { $0.isWhitespace }.count
        let trimmed = String(text.dropFirst(leadingWS).dropLast(trailingWS))
        let coreStart = range.location + leadingWS
        let coreLength = range.length - leadingWS - trailingWS
        return (trimmed, coreStart, coreLength)
    }
    /// Prüft, ob die Auswahl bereits von ** umschlossen ist (sucht sowohl innen als auch außen)
   func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        let (trimmed, _, _) = trimmedCore(in: nsText, range: range)
        // If trimmed selection contains any '*' or '#', treat as already formatted
        if trimmed.contains("*") || trimmed.contains("#") {
            return true
        }
      
        // Case 2: markers directly outside the selected range
        let length = range.length
        if range.location >= 2,
           nsText.substring(with: NSRange(location: range.location - 2, length: 2)) == "**",
           range.location + length + 2 <= nsText.length,
           nsText.substring(with: NSRange(location: range.location + length, length: 2)) == "**" {
            return true
        }
        return false
    }
    /// Prüft, ob die Auswahl bereits von * umschlossen ist (sucht sowohl innen als auch außen)
    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        let (trimmed, _, _) = trimmedCore(in: nsText, range: range)
        // If trimmed selection contains any '*' or '#', treat as already formatted
        if trimmed.contains("*") || trimmed.contains("#") {
            return true
        }
        // Case 1: markers inside selection after trimming whitespace
        if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") {
            return true
        }
        let length = range.length
        // Case 3: bold+italic markers directly outside the selected range
        if range.location >= 3,
           nsText.substring(with: NSRange(location: range.location - 3, length: 3)) == "***",
           range.location + length + 3 <= nsText.length,
           nsText.substring(with: NSRange(location: range.location + length, length: 3)) == "***"
        {
            return true
        }
        // Case 2: markers directly outside the selected range (ensure not part of bold markers)
        if range.location >= 1,
           nsText.substring(with: NSRange(location: range.location - 1, length: 1)) == "*",
           range.location + length + 1 <= nsText.length,
           nsText.substring(with: NSRange(location: range.location + length, length: 1)) == "*",
           // ensure not part of bold markers: no extra "*" before or after
           (range.location < 2 || nsText.substring(with: NSRange(location: range.location - 2, length: 1)) != "*"),
           (range.location + length + 2 > nsText.length || nsText.substring(with: NSRange(location: range.location + length + 1, length: 1)) != "*")
        {
            return true
        }
        return false
    }
    /// Prüft, ob die Auswahl in einer Zeile bereits als Heading der gegebenen Ebene formatiert ist
    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    /// Prüft, ob die Auswahl in einer Zeile bereits als Liste formatiert ist
    func isSelectionList(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("\t• ") || line.hasPrefix("1. ")
    }

    /// Applies the given Markdown heading level to the current line
    private func applyHeading(level: Int) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let rawLine = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        var content = rawLine
        while content.hasPrefix("#") { content.removeFirst() }
        content = content.trimmingCharacters(in: .whitespaces)
        let prefix = String(repeating: "#", count: level) + " "
        let newLine = prefix + content
        if tv.shouldChangeText(in: lineRange, replacementString: newLine) {
            tv.replaceCharacters(in: lineRange, with: newLine)
            tv.didChangeText()
            let newSel = NSRange(location: lineRange.location + prefix.count, length: content.count)
            tv.setSelectedRange(newSel)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        applyHeading(level: sender.tag)
    }

    /// Applies a Markdown list prefix to the entire line containing the selection
    private func applyList(prefix: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let startLine = nsText.lineRange(for: selRange)
        let originalLine = nsText.substring(with: startLine)
        let lineText = originalLine.trimmingCharacters(in: .newlines)
        var content = lineText
        if content.hasPrefix(prefix) {
            content = String(content.dropFirst(prefix.count))
        }
        let newLine = prefix + content
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let replacement = newLine + suffix
        if tv.shouldChangeText(in: startLine, replacementString: replacement) {
            tv.replaceCharacters(in: startLine, with: replacement)
            tv.didChangeText()
            let newSel = NSRange(location: startLine.location + prefix.count, length: content.count)
            tv.setSelectedRange(newSel)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        applyList(prefix: "\t• ")
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        applyList(prefix: "1. ")
    }
    @objc func didMarkdownBold(_ sender: Any?) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        // If nothing is selected, insert empty bold markers and place cursor between them
        if range.length == 0 {
            let prefix = "**"
            let insertion = prefix + prefix
            if tv.shouldChangeText(in: range, replacementString: insertion) {
                tv.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
                let cursorRange = NSRange(location: range.location + prefix.count, length: 0)
                tv.setSelectedRange(cursorRange)
                DispatchQueue.main.async { self.text = tv.string }
            }
            return
        }
        // Wenn bereits Fett, nichts tun
        if isSelectionBold(in: nsText, range: range) {
            return
        }

        // Otherwise wrap selection, ignoring leading/trailing whitespace
        let original = nsText.substring(with: range)
        // Calculate leading and trailing whitespace counts
        let wrapLeadingWhitespaceCount = original.prefix { $0.isWhitespace }.count
        let wrapTrailingWhitespaceCount = original.reversed().prefix { $0.isWhitespace }.count
        // Determine core text range within original
        let wrapCoreStart = original.index(original.startIndex, offsetBy: wrapLeadingWhitespaceCount)
        let wrapCoreEnd = original.index(original.endIndex, offsetBy: -wrapTrailingWhitespaceCount)
        let core: String
        if wrapCoreStart <= wrapCoreEnd {
            core = String(original[wrapCoreStart..<wrapCoreEnd])
        } else {
            core = ""
        }
        let leading = String(original[..<wrapCoreStart])
        let trailing = String(original[wrapCoreEnd...])
        // Wrap only the core text with bold markers
        let wrappedCore = "**\(core)**"
        let newText = leading + wrappedCore + trailing
        if tv.shouldChangeText(in: range, replacementString: newText) {
            tv.replaceCharacters(in: range, with: newText)
            tv.didChangeText()
            // Select only the bolded core content
            let newRangeLocation = range.location + wrapLeadingWhitespaceCount + 2
            let newRangeLength = core.count
            let newRange = NSRange(location: newRangeLocation, length: newRangeLength)
            tv.setSelectedRange(newRange)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        // If nothing is selected, insert empty italic markers and place cursor between them
        if range.length == 0 {
            let prefix = "*"
            let insertion = prefix + prefix
            if tv.shouldChangeText(in: range, replacementString: insertion) {
                tv.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
                let cursorRange = NSRange(location: range.location + prefix.count, length: 0)
                tv.setSelectedRange(cursorRange)
                DispatchQueue.main.async { self.text = tv.string }
            }
            return
        }
        // Wenn bereits Kursiv, nichts tun
        if isSelectionItalic(in: nsText, range: range) {
            return
        }

        // Otherwise wrap selection, ignoring leading/trailing whitespace
        let original = nsText.substring(with: range)
        let leadingWS = original.prefix { $0.isWhitespace }.count
        let trailingWS = original.reversed().prefix { $0.isWhitespace }.count
        let wrapCoreStart = original.index(original.startIndex, offsetBy: leadingWS)
        let wrapCoreEnd = original.index(original.endIndex, offsetBy: -trailingWS)
        let core: String
        if wrapCoreStart <= wrapCoreEnd {
            core = String(original[wrapCoreStart..<wrapCoreEnd])
        } else {
            core = ""
        }
        let leading = String(original[..<wrapCoreStart])
        let trailing = String(original[wrapCoreEnd...])
        let wrappedCore = "*\(core)*"
        let newText = leading + wrappedCore + trailing

        if tv.shouldChangeText(in: range, replacementString: newText) {
            tv.replaceCharacters(in: range, with: newText)
            tv.didChangeText()
            let newRangeLocation = range.location + leadingWS + 1
            let newRangeLength = core.count
            let newRange = NSRange(location: newRangeLocation, length: newRangeLength)
            tv.setSelectedRange(newRange)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }
}

// MARK: - Menu Item Validation for Format commands
extension NativeTextViewWrapper.Coordinator: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tv = textView else { return true }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        switch menuItem.action {
        case #selector(didMarkdownBold(_:)):
            return !isSelectionBold(in: nsText, range: range)
        case #selector(didMarkdownItalic(_:)):
            return !isSelectionItalic(in: nsText, range: range)
        case #selector(didMarkdownHeading(_:)):
            let level = menuItem.tag
            return !isSelectionHeading(level: level, in: nsText, range: range)
        case #selector(didMarkdownUnorderedList(_:)),
             #selector(didMarkdownOrderedList(_:)):
            return !isSelectionList(in: nsText, range: range)
        default:
            return true
        }
    }
}
