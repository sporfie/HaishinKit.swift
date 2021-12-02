import Foundation
import Logboard

protocol SRTSocketDelegate: AnyObject {
	func status(_ socket: SRTSocket, status: SRT_SOCKSTATUS)
}

public typealias SRTStatistics = SRT_TRACEBSTATS

open class SRTSocket {
	static let defaultOptions: [SRTSocketOption: Any] = [:]
	static let payloadSize: Int = 1316
	public static func statusToStr(status : SRT_SOCKSTATUS) -> String {
		switch status {
		case SRTS_INIT: // 1
			return "Init"
		case SRTS_OPENED:
			return "Opened"
		case SRTS_LISTENING:
			return "Listening"
		case SRTS_CONNECTING:
			return "Connecting"
		case SRTS_CONNECTED:
			return "Connected"
		case SRTS_BROKEN:
			return "Broken"
		case SRTS_CLOSING:
			return "Closing"
		case SRTS_CLOSED:
			return "Closed"
		case SRTS_NONEXIST:
			return "Invalid"
		default:
			return "Unknown status"
		}
	}
	
	private var pendingData: [Data] = []
	private let writeQueue: DispatchQueue = DispatchQueue(label: "com.haishinkit.srt.SRTSocket.write")
	private let lockQueue: DispatchQueue = DispatchQueue(label: "com.haishinkit.SRTHaishinKit.SRTSocket.lock")

	var timeout: Int = 0
	var options: [SRTSocketOption: Any] = [:] {
		didSet {
			options[.rcvsyn] = true
			options[.tsbdmode] = true
		}
	}
	weak var delegate: SRTSocketDelegate?
	
	private(set) var uri: URL?
	private(set) var socket: SRTSOCKET = SRT_INVALID_SOCK
	private(set) var status: SRT_SOCKSTATUS = SRTS_INIT {
		didSet {
			guard status != oldValue else { return }
			delegate?.status(self, status: status)
			logger.trace("SRT Socket status updated to \(SRTSocket.statusToStr(status: status))")
			if status == SRTS_BROKEN { close() }
			else if status == SRTS_CLOSED { stopRunning() }
		}
	}
	public var isRunning: Atomic<Bool> = .init(false)

	public var stats : SRTStatistics {
		var s = SRT_TRACEBSTATS()
		_ = srt_bstats(socket, &s, 0)
		return s
	}
	
	private func sockaddr_in(_ host: String, port: UInt16) -> sockaddr_in {
		var addr: sockaddr_in = .init()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = CFSwapInt16BigToHost(UInt16(port))
		if inet_pton(AF_INET, host, &addr.sin_addr) == 1 { return addr }
		guard let hostent = gethostbyname(host), hostent.pointee.h_addrtype == AF_INET else { return addr }
		addr.sin_addr = UnsafeRawPointer(hostent.pointee.h_addr_list[0]!).assumingMemoryBound(to: in_addr.self).pointee
		return addr
	}

	public init() {
	}
	
	func connect(uri: URL) throws {
		guard socket == SRT_INVALID_SOCK else { return }
		guard let scheme = uri.scheme, let host = uri.host, let port = uri.port, scheme == "srt" else {
			throw SRTError.invalidURL(message: "Invalid SRT url")
		}

		self.uri = uri

		// prepare socket
		socket = srt_create_socket()
		if socket == SRT_ERROR {
			let error_message = String(cString: srt_getlasterror_str())
			logger.error(error_message)
			throw SRTError.illegalState(message: error_message)
		}
		
		self.options = SRTSocketOption.from(uri: uri)
		guard configure(.pre) else { return }
		
		// prepare connect
		let addr = sockaddr_in(host, port: UInt16(port))
		var addr_cp = addr
		let stat = withUnsafePointer(to: &addr_cp) { ptr -> Int32 in
			let psa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
			let err = srt_connect(socket, psa, Int32(MemoryLayout.size(ofValue: addr)))
			return err
		}
		
		if stat == SRT_ERROR {
			let error_message = String(cString: srt_getlasterror_str())
			logger.error(error_message)
			throw SRTError.illegalState(message: error_message)
		}
		
		guard configure(.post) else { return }
		startRunning()
	}
	
	func write(_ data: Data) {
		writeQueue.async {
			self.pendingData.append(contentsOf: data.chunk(SRTSocket.payloadSize))
			while !self.pendingData.isEmpty {
				let data = self.pendingData.removeFirst()
				data.withUnsafeBytes {
					let bytes = $0.bindMemory(to: Int8.self)
					srt_sendmsg2(self.socket, bytes.baseAddress, Int32(data.count), nil)
				}
			}
		}
	}
	
	func close() {
		guard socket != SRT_INVALID_SOCK else { return }
		srt_close(socket)
		socket = SRT_INVALID_SOCK
	}
	
	func configure(_ binding: SRTSocketOption.Binding) -> Bool {
		if binding == .post {
			options[.sndsyn] = true
			if 0 < timeout {
				options[.sndtimeo] = timeout
			}
		}
		let failures = SRTSocketOption.configure(socket, binding: binding, options: options)
		guard failures.isEmpty else {
			logger.error(failures)
			return false
		}
		return true
	}
	
}

// Polling version
// We get the status of the socket by polling the API
// This means that we may miss some state transition
extension SRTSocket: Running {
	// MARK: Running
	public func startRunning() {
		lockQueue.async {
			self.isRunning.mutate { $0 = true }
			repeat {
				self.status = srt_getsockstate(self.socket)
				usleep(3 * 10000)
			} while self.isRunning.value
		}
	}

	public func stopRunning() {
		isRunning.mutate { $0 = false }
	}
}

// Blocking version
// We watch for state changes through a blocking API.
// In theory we should be able to get all state changes this way,
// but when a socket is closed, it is automatically removed from the EPOLL pool
// which results in an error from srt_epoll_uwait (with a varying error code),
// so we actuayll don't get more information this way.
//extension SRTSocket: Running {
//	// MARK: Running
//	public func startRunning() {
//		lockQueue.async {
//			self.isRunning.mutate { $0 = true }
//			let eid = srt_epoll_create()
//			if eid == -1 {
//				logger.error("SRT Socket failed to create EPOLL")
//				return
//			}
//			let err = srt_epoll_add_usock(eid, self.socket, nil)
//			if err < 0 {
//				logger.error("SRT Socket failed to add socket to EPOLL")
//				srt_epoll_release(eid)
//				return
//			}
//
//			repeat {
//				let events = Int32(SRT_EPOLL_IN.rawValue | SRT_EPOLL_OUT.rawValue | SRT_EPOLL_ERR.rawValue | SRT_EPOLL_CONNECT.rawValue | SRT_EPOLL_UPDATE.rawValue)
//				var fdsSet = [SRT_EPOLL_EVENT(fd: self.socket, events:events)]
//				let err = srt_epoll_uwait(eid, &fdsSet, 1, -1)
//				if err < 0 {
//					var error: Int32 = 0
//					srt_getlasterror(&error)
//					let error_message = String(cString: srt_getlasterror_str())
//					logger.error("SRT Socket failed to wait on EPOLL: \(error) \(error_message)")
//				}
//				self.status = srt_getsockstate(self.socket)
//			} while self.isRunning.value
//
//			srt_epoll_remove_ssock(eid, self.socket)
//			srt_epoll_release(eid)
//		}
//	}
//
//	public func stopRunning() {
//		isRunning.mutate { $0 = false }
//	}
//}
