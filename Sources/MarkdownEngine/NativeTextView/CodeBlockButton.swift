//
//  CodeBlockButton.swift
//  Nodes
//
//  Created by Luca Chen on 15.12.25
//  Purpose: Shows a small copy button overlay for each code block.
//

import SwiftUI

public struct CodeBlockSelection: Identifiable, Sendable {
    public let id: Int // Token index
    public let rect: CGRect
    public let language: String?
    public let code: String

    public init(id: Int, rect: CGRect, language: String?, code: String) {
        self.id = id
        self.rect = rect
        self.language = language
        self.code = code
    }
}

public struct CodeBlockButton: View {
    public let selection: CodeBlockSelection
    public let onCopy: () -> Void

    public init(selection: CodeBlockSelection, onCopy: @escaping () -> Void) {
        self.selection = selection
        self.onCopy = onCopy
    }

    public var body: some View {
        // Invisible frame matching code block position & size
        Color.clear
            .frame(width: selection.rect.width, height: selection.rect.height)
            .overlay(alignment: .topTrailing) {
                Button(action: onCopy) {
                    HStack(spacing: 6) {
                        if let lang = selection.language, !lang.isEmpty {
                            Text(lang.uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, -25)
            }
            .position(
                x: selection.rect.midX,
                y: selection.rect.midY
            )
    }
}
