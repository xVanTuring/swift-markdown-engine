//
//  WikiLinkService.swift
//  Nodes
//
//  Generic wiki-link transformer used by the editor engine.
//
//  Wiki-links live in two forms:
//    Storage form    [[Name|<opaque-id>]]
//    Display form    [[Name]]
//
//  This service converts between the two and maintains a metadata map
//  that lets callers look up the storage range and identifier for any
//  display occurrence. The identifier is opaque to the engine — it can
//  be a UUID, a slug, a database key, anything an embedder hands out
//  via the ``WikiLinkResolver`` protocol.
//

import AppKit
import Foundation
import os

/// Bidirectional transform between the storage and display forms of wiki-links.
public enum WikiLinkService {

    /// Hashable wrapper around `NSRange` so we can use it as a dictionary key.
    public struct RangeKey: Hashable, Sendable {
        public let location: Int
        public let length: Int

        public init(_ range: NSRange) {
            self.location = range.location
            self.length = range.length
        }
    }

    /// Identifier and storage-side range associated with a display occurrence.
    public struct LinkMetadata: Sendable {
        public let id: String?
        public let storageRange: NSRange

        public init(id: String?, storageRange: NSRange) {
            self.id = id
            self.storageRange = storageRange
        }
    }

    /// Regex pattern matching the storage form `[[Name|optional-id]]`.
    public static let storagePattern = #"(?<!!)\[\[([^\|\]\r\n]*)(?:\|([^\]\r\n]+))?\]\]"#
    /// Regex pattern matching the display form `[[Name]]` (no `|`).
    public static let displayPattern = #"(?<!!)\[\[([^\]\r\n]*)\]\]"#

    private static let storageLinkRegex = try! NSRegularExpression(pattern: storagePattern)
    private static let displayLinkRegex = try! NSRegularExpression(pattern: displayPattern)
    private static let logger = Logger(subsystem: "com.markdownengine.wikilinks", category: "WikiLink")

    public static func makeDisplayState(from storageText: String) -> (display: String, metadata: [RangeKey: LinkMetadata]) {
        let nsStorage = storageText as NSString
        let fullRange = NSRange(location: 0, length: nsStorage.length)
        var result = ""
        result.reserveCapacity(storageText.count)
        var metadata: [RangeKey: LinkMetadata] = [:]
        var cursor = 0
        var displayLength = 0

        for match in storageLinkRegex.matches(in: storageText, options: [], range: fullRange) {
            let prefixLength = match.range.location - cursor
            if prefixLength > 0 {
                let prefixRange = NSRange(location: cursor, length: prefixLength)
                let prefix = nsStorage.substring(with: prefixRange)
                result.append(prefix)
                displayLength += prefix.utf16.count
                cursor += prefixLength
            }

            let nameRange = match.range(at: 1)
            let name = nsStorage.substring(with: nameRange)
            let displayFragment = "[[\(name)]]"
            let displayRange = NSRange(location: displayLength, length: displayFragment.utf16.count)
            result.append(displayFragment)
            displayLength += displayFragment.utf16.count

            var linkID: String? = nil
            if match.numberOfRanges > 2 {
                let idRange = match.range(at: 2)
                if idRange.location != NSNotFound && idRange.length > 0 {
                    linkID = nsStorage.substring(with: idRange)
                }
            }
            metadata[RangeKey(displayRange)] = LinkMetadata(id: linkID, storageRange: match.range)
            cursor = match.range.location + match.range.length
        }

        if cursor < nsStorage.length {
            let suffixRange = NSRange(location: cursor, length: nsStorage.length - cursor)
            result.append(nsStorage.substring(with: suffixRange))
        }

        return (result, metadata)
    }

    public static func makeStorageState(
        from displayText: String,
        existingMetadata: [RangeKey: LinkMetadata],
        textStorage: NSTextStorage?
    ) -> (storage: String, metadata: [RangeKey: LinkMetadata]) {
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)
        var storage = ""
        storage.reserveCapacity(displayText.count)
        var metadata: [RangeKey: LinkMetadata] = [:]
        var cursor = 0
        var storageLength = 0

        for match in displayLinkRegex.matches(in: displayText, options: [], range: fullRange) {
            let prefixLength = match.range.location - cursor
            if prefixLength > 0 {
                let prefixRange = NSRange(location: cursor, length: prefixLength)
                let prefix = nsDisplay.substring(with: prefixRange)
                storage.append(prefix)
                storageLength += prefix.utf16.count
                cursor += prefixLength
            }

            let contentLength = max(0, match.range.length - 4)
            let contentRange = NSRange(location: match.range.location + 2, length: contentLength)
            let name = nsDisplay.substring(with: contentRange)

            var linkID: String? = nil
            if contentRange.length > 0 {
                if let idAttr = textStorage?.attribute(.nodeLinkID, at: contentRange.location, effectiveRange: nil) as? String {
                    linkID = idAttr
                }
            }
            if linkID == nil {
                linkID = existingMetadata[RangeKey(match.range)]?.id
            }

            let storageFragment: String
            if let linkID, !linkID.isEmpty {
                storageFragment = "[[\(name)|\(linkID)]]"
            } else {
                storageFragment = "[[\(name)]]"
            }
            let fragmentLength = storageFragment.utf16.count
            let storageRange = NSRange(location: storageLength, length: fragmentLength)
            storage.append(storageFragment)
            storageLength += fragmentLength

            metadata[RangeKey(match.range)] = LinkMetadata(id: linkID, storageRange: storageRange)
            cursor = match.range.location + match.range.length
        }

        if cursor < nsDisplay.length {
            let suffixRange = NSRange(location: cursor, length: nsDisplay.length - cursor)
            storage.append(nsDisplay.substring(with: suffixRange))
        }

        return (storage, metadata)
    }

    public static func resolveIdentifier(link: Any, textView: NSTextView, at charIndex: Int) -> String? {
        if let idAttr = textView.textStorage?.attribute(.nodeLinkID, at: charIndex, effectiveRange: nil) as? String {
            return idAttr
        }
        if let name = link as? String {
            return name
        }
        return nil
    }

    public static func displayFragmentAndID(from storageFragment: String) -> (display: String, id: String?) {
        let displayState = makeDisplayState(from: storageFragment)
        return (displayState.display, displayState.metadata.values.first?.id)
    }

    public static func caretRangeAfterReplacing(
        displayRange: NSRange,
        with storageFragment: String
    ) -> NSRange {
        let displayFragment = makeDisplayState(from: storageFragment).display as NSString
        return NSRange(location: displayRange.location + displayFragment.length, length: 0)
    }
}

