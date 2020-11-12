//
//  RTMPBlueSocket.swift
//  HaishinKit
//
//  Created by Guy on 12.11.20.
//  Copyright © 2020 Shogo Endo. All rights reserved.
//

import Socket

final class RTMPBlueSocket: RTMPSocketCompatible {
	let writeTimeOut : UInt = 300
    var timestamp: TimeInterval = 0.0
    var chunkSizeC: Int = RTMPChunk.defaultSize
    var chunkSizeS: Int = RTMPChunk.defaultSize
    var windowSizeC = Int(UInt8.max)
    var timeout: Int = NetSocket.defaultTimeout
    var readyState: RTMPSocketReadyState = .uninitialized {
        didSet {
            delegate?.didSetReadyState(readyState)
        }
    }
    var securityLevel: StreamSocketSecurityLevel = .none
    var qualityOfService: DispatchQoS = .default
    var inputBuffer = Data()
    weak var delegate: RTMPSocketDelegate?

    private(set) var queueBytesOut: Atomic<Int64> = .init(0)
    private(set) var totalBytesIn: Atomic<Int64> = .init(0)
    private(set) var totalBytesOut: Atomic<Int64> = .init(0)
    private(set) var connected = false {
        didSet {
            if connected {
                doOutput(data: handshake.c0c1packet)
                readyState = .versionSent
                return
            }
            readyState = .closed
            for event in events {
                delegate?.dispatch(event: event)
            }
            events.removeAll()
        }
    }
    private var events: [Event] = []
    private var handshake = RTMPHandshake()
    private var connection: Socket? {
        didSet {
            oldValue?.close()
            if connection == nil {
                connected = false
            }
        }
    }
    private lazy var inputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NWSocket.input", qos: qualityOfService)
    private lazy var outputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NWSocket.output", qos: qualityOfService)

    func connect(withName: String, port: Int) {
        handshake.clear()
        readyState = .uninitialized
        chunkSizeS = RTMPChunk.defaultSize
        chunkSizeC = RTMPChunk.defaultSize
        totalBytesIn.mutate { $0 = 0 }
        totalBytesOut.mutate { $0 = 0 }
        queueBytesOut.mutate { $0 = 0 }
        inputBuffer.removeAll(keepingCapacity: false)
		connection = try? Socket.create()
		guard connection != nil else { return }
		inputQueue.async {
			try? self.connection!.connect(to: withName, port: Int32(port), timeout: UInt(self.timeout*1000))
			if self.connection!.isConnected {
//				try? self.connection?.setWriteTimeout(value: self.writeTimeOut)
				self.connected = true
				self.receive()
			} else {
				self.close(isDisconnected: true)
			}
		}
    }

    func close(isDisconnected: Bool) {
        guard connection != nil else { return }
        if isDisconnected {
            let data: ASObject = (readyState == .handshakeDone) ?
                RTMPConnection.Code.connectClosed.data("") : RTMPConnection.Code.connectFailed.data("")
            events.append(Event(type: .rtmpStatus, bubbles: false, data: data))
        }
        readyState = .closing
        connection = nil
    }

    @discardableResult
    func doOutput(chunk: RTMPChunk, locked: UnsafeMutablePointer<UInt32>? = nil) -> Int {
        let chunks: [Data] = chunk.split(chunkSizeS)
        for i in 0..<chunks.count - 1 {
            doOutput(data: chunks[i])
        }
        doOutput(data: chunks.last!, locked: locked)
        if logger.isEnabledFor(level: .trace) {
            logger.trace(chunk)
        }
        return chunk.message!.length
    }

    @discardableResult
    func doOutput(data: Data, locked: UnsafeMutablePointer<UInt32>? = nil) -> Int {
        queueBytesOut.mutate { $0 += Int64(data.count) }
        outputQueue.async {
			do {
				let then = CACurrentMediaTime()
				let count = try self.connection?.write(from: data)
				//			if count == 0 {
				//				self.close(isDisconnected: true)
				//				return
				//			}
				let elapsed = Int((CACurrentMediaTime()-then)*1000)
				if elapsed > self.writeTimeOut || (count == 0 && errno == EAGAIN) {
					print("*********** sent \(count!) \(elapsed)")
				} else {
					print("sent \(count ?? -100) in \(elapsed)")
				}
			} catch {
				print(error)
			}
			self.totalBytesOut.mutate { $0 += Int64(data.count) }
			self.queueBytesOut.mutate { $0 -= Int64(data.count) }
        }
        return data.count
    }

    func setProperty(_ value: Any?, forKey: String) {
    }

    private func receive() {
		var data = Data(capacity: windowSizeC)
		let count = (try? connection?.read(into: &data)) ?? 0
		guard count > 0 else { return }
		self.inputBuffer.append(data)
		self.totalBytesIn.mutate { $0 += Int64(data.count) }
		self.listen()
		self.receive()
    }

    private func listen() {
        switch readyState {
        case .versionSent:
            if inputBuffer.count < RTMPHandshake.sigSize + 1 {
                break
            }
            doOutput(data: handshake.c2packet(inputBuffer))
            inputBuffer.removeSubrange(0...RTMPHandshake.sigSize)
            readyState = .ackSent
            if RTMPHandshake.sigSize <= inputBuffer.count {
                listen()
            }
        case .ackSent:
            if inputBuffer.count < RTMPHandshake.sigSize {
                break
            }
            inputBuffer.removeAll()
            readyState = .handshakeDone
        case .handshakeDone:
            if inputBuffer.isEmpty {
                break
            }
            let bytes: Data = inputBuffer
            inputBuffer.removeAll()
            delegate?.listen(bytes)
        default:
            break
        }
    }
}
