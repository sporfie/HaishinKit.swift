import Foundation
import AVFoundation
import SporfieSRT

open class SRTStream: NetStream {
    public enum ReadyState {
        case initialized
		case connected
        case publishing
    }

	public private(set) var socket = SRTSocket()
	public private(set) var uri: URL!
	
    private var action: (() -> Void)?
    private var keyValueObservations: [NSKeyValueObservation] = []
    private lazy var tsWriter: TSWriter = {
        var tsWriter = TSWriter()
        tsWriter.delegate = self
        return tsWriter
    }()

    public private(set) var readyState: ReadyState = .initialized
	public init(url: URL) {
        super.init()
		self.uri = url
		socket.delegate = self
    }

    deinit {
		socket.close()
    }

    override open func attachCamera(_ camera: AVCaptureDevice?, onError: ((NSError) -> Void)? = nil) {
        if camera == nil {
            tsWriter.expectedMedias.remove(.video)
        } else {
            tsWriter.expectedMedias.insert(.video)
        }
        super.attachCamera(camera, onError: onError)
    }

    override open func attachAudio(_ audio: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool = true, onError: ((NSError) -> Void)? = nil) {
        if audio == nil {
            tsWriter.expectedMedias.remove(.audio)
        } else {
            tsWriter.expectedMedias.insert(.audio)
        }
        super.attachAudio(audio, automaticallyConfiguresApplicationAudioSession: automaticallyConfiguresApplicationAudioSession, onError: onError)
    }

	func startPump() {
		mixer.startEncoding(delegate: self.tsWriter)
		mixer.startRunning()
		tsWriter.startRunning()
		readyState = .publishing
	}
	
	func stopPump() {
		tsWriter.stopRunning()
		mixer.stopEncoding()
		readyState = .connected
	}
	
    open func publish() {
        lockQueue.async {
			switch self.readyState {
			case .initialized:
				try? self.socket.connect(uri: self.uri)
				break
			case .connected:
				break
			case .publishing:
				break
			}
		}
    }

    override open func close() {
        lockQueue.async {
			switch self.readyState {
			case .initialized:
				break
			case .connected:
				self.socket.close()
				break
			case .publishing:
				self.stopPump()
				self.socket.close()
				break
			}
			self.readyState = .initialized
        }
    }
}

extension SRTStream: SRTSocketDelegate {
	public func status(_ socket: SRTSocket, status: SRT_SOCKSTATUS) {
		lockQueue.async {
			switch self.readyState {
			case .initialized:
				if status == SRTS_CONNECTED {
					self.readyState = .connected
					self.startPump()
				}
				break
			case .connected:
				if status == SRTS_BROKEN { self.close() }
				break
			case .publishing:
				if status == SRTS_BROKEN { self.close() }
				break
			}
		}
	}
}

extension SRTStream: TSWriterDelegate {
    // MARK: TSWriterDelegate
    public func didOutput(_ data: Data) {
        guard readyState == .publishing else { return }
        socket.write(data)
    }
}
