import Foundation

/// 用户自定义标签。
public struct ClipboardLabel: Identifiable, Equatable, Hashable {
    public let id: Int64
    public var name: String
    /// 预设色名：blue / purple / pink / red / orange / yellow / green / gray
    public var color: String
    public var sortOrder: Int
    public let createdAt: Date

    public init(id: Int64, name: String, color: String, sortOrder: Int, createdAt: Date) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    public static let presetColors = [
        "blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"
    ]
}

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
    public let sourceAppBundleID: String?
    public let labelIDs: [Int64]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int64,
        kind: Kind,
        text: String?,
        rtfPath: String?,
        imagePath: String?,
        originalImagePath: String?,
        filePaths: [String],
        hash: String,
        pinned: Bool,
        sourceAppBundleID: String? = nil,
        labelIDs: [Int64] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtfPath = rtfPath
        self.imagePath = imagePath
        self.originalImagePath = originalImagePath
        self.filePaths = filePaths
        self.hash = hash
        self.pinned = pinned
        self.sourceAppBundleID = sourceAppBundleID
        self.labelIDs = labelIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 列表里显示的主文本.
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

/// 一次历史列表查询的完整快照，保证条目与计数来自同一条存储队列。
public struct ClipboardHistoryPage: Equatable {
    public let items: [ClipboardItem]
    public let totalCount: Int
    public let matchCount: Int

    public init(items: [ClipboardItem], totalCount: Int, matchCount: Int) {
        self.items = items
        self.totalCount = totalCount
        self.matchCount = matchCount
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
    public let sourceAppBundleID: String?

    public init(
        kind: ClipboardItem.Kind,
        text: String? = nil,
        rtfPath: String? = nil,
        imagePath: String? = nil,
        originalImagePath: String? = nil,
        filePaths: [String] = [],
        hash: String,
        sourceAppBundleID: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.rtfPath = rtfPath
        self.imagePath = imagePath
        self.originalImagePath = originalImagePath
        self.filePaths = filePaths
        self.hash = hash
        self.sourceAppBundleID = sourceAppBundleID
    }
}
