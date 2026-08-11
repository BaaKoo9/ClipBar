import Foundation

/// 设置页「优雅更新」进度状态。
@MainActor
final class UpdateProgressModel: ObservableObject {
    static let shared = UpdateProgressModel()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// 0...1，仅 downloading 时有意义。
    @Published var fractionCompleted: Double = 0
    @Published var statusText: String = ""

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func reset() {
        phase = .idle
        fractionCompleted = 0
        statusText = ""
    }
}
