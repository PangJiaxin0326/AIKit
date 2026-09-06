import AIKitRuntime
import VolcengineArkFoundationModels

extension VolcengineArkError: AIKitRetryClassifyingError {
    public var aiKitErrorCategory: ErrorCategory {
        switch self {
        case .httpStatus(let code, _):
            (code == 429 || (500..<600).contains(code)) ? .transient : .fatal
        case .transport: .transient
        default: .fatal
        }
    }
}
