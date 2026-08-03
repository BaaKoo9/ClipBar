import Foundation

/// 一条剪贴板历史记录。
public struct ClipboardItem: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        case text
        case link
        case image
        case file
    }

    public let id: Int64
    public let kind: Kind
    public let text: String?
    public let rtfPath: String?
    public let imagePath: String?
    public let originalImagePath: String?
    public let filePaths: [String]
    public let hash: String
    public let pinned: Bool
    public let createdAt: Date
    public let updatedAt: Date

    /// 列表里显示的主文本。
    public var displayText: String {
        switch kind {
        case .text, .link:
            return text ?? ""
        case .file:
            return filePaths
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: " · ")
        case .image:
            return "图片"
        }
    }

    /// 单行预览（用于列表行）。
    public var previewLine: String {
        let text = displayText.replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(200))
    }
}

/// 准备写入历史的新记录。
public struct NewClipboardItem {
    public let kind: ClipboardItem.Kind
    public let text: String?
    public let rtfPath: String?
    public let imagePath: String?
    public let originalImagePath: String?
    public let filePaths: [String]
    public let hash: String

    public init(
        kind: ClipboardItem.Kind,
        text: String? = nil,
        rtfPath: String? = nil,
        imagePath: String? = nil,
        originalImagePath: String? = nil,
        filePaths: [String] = [],
        hash: String
    ) {
        self.kind = kind
        self.text = text
        self.rtfPath = rtfPath
        self.imagePath = imagePath
        self.originalImagePath = originalImagePath
        self.filePaths = filePaths
        self.hash = hash
    }
}
