import Foundation

enum SRTError: Error {
	case invalidURL(message: String)
	case illegalState(message: String)
    case invalidArgument(message: String)
}
