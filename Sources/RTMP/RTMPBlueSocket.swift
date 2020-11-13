//
//  RTMPBlueSocket.swift
//  HaishinKit
//
//  Created by Guy on 12.11.20.
//  Copyright © 2020 Shogo Endo. All rights reserved.
//

import Socket

open class RTMPBlueSocket: RTMPSocketCompatible {
	open var writeTimeOut = 500.0

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

    var queueBytesOut: Atomic<Int64> = .init(0)
    var totalBytesIn: Atomic<Int64> = .init(0)
    var totalBytesOut: Atomic<Int64> = .init(0)
    var totalBytesDiscarded: Atomic<Int64> = .init(0)
    var connected = false {
        didSet {
            if connected {
				outputQueue.async {
					self.send(data: self.handshake.c0c1packet)
				}
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
    var events: [Event] = []
    var handshake = RTMPHandshake()
    var connection: Socket? {
        didSet {
            oldValue?.close()
            if connection == nil {
                connected = false
            }
        }
    }
    lazy var inputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NWSocket.input", qos: qualityOfService)
    lazy var outputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NWSocket.output", qos: qualityOfService)

    func connect(withName: String, port: Int) {
        handshake.clear()
        readyState = .uninitialized
        chunkSizeS = RTMPChunk.defaultSize
        chunkSizeC = RTMPChunk.defaultSize
        totalBytesIn.mutate { $0 = 0 }
        totalBytesOut.mutate { $0 = 0 }
        queueBytesOut.mutate { $0 = 0 }
        totalBytesDiscarded.mutate { $0 = 0 }
        inputBuffer.removeAll(keepingCapacity: false)
		connection = try? Socket.create()
		guard connection != nil else { return }
		inputQueue.async {
			try? self.connection!.connect(to: withName, port: Int32(port), timeout: UInt(self.timeout*1000))
			if self.connection!.isConnected {
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
		let queuedAt = CACurrentMediaTime()
        outputQueue.async {
			let then = CACurrentMediaTime()
			let queuedFor = (then-queuedAt)*1000
			guard queuedFor < self.writeTimeOut else {
				self.totalBytesDiscarded.mutate { $0 += Int64(chunk.data.count) }
				print("discarded \(chunk.data.count) after \(Int(queuedFor))")
				return
			}
			
			let chunks: [Data] = chunk.split(self.chunkSizeS)
			for i in 0..<chunks.count - 1 {
				self.send(data: chunks[i])
			}
			self.send(data: chunks.last!, locked: locked)
		}
        if logger.isEnabledFor(level: .trace) {
            logger.trace(chunk)
        }
        return chunk.message!.length
    }

    @discardableResult
    func send(data: Data, locked: UnsafeMutablePointer<UInt32>? = nil) -> Int {
		guard connected else { return 0 }
        queueBytesOut.mutate { $0 += Int64(data.count) }
		do {
			let then = CACurrentMediaTime()
			let count = try self.connection?.write(from: data)
			let elapsed = (CACurrentMediaTime()-then)*1000
			if elapsed > self.writeTimeOut {
				print("*********** sent \(count!) \(Int(elapsed))")
			}
		} catch {
			print(error)
		}
		self.totalBytesOut.mutate { $0 += Int64(data.count) }
		self.queueBytesOut.mutate { $0 -= Int64(data.count) }
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
			let data = handshake.c2packet(inputBuffer)
			outputQueue.async {
				self.send(data: data)
			}
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
