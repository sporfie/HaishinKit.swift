//
//  RTMPBlueSocket.swift
//  HaishinKit
//
//  Created by Guy on 12.11.20.
//  Copyright © 2020 Sporfie. All rights reserved.
//

import Foundation
import Socket

open class RTMPBlueSocket: RTMPSocketCompatible {	
	public class Statistics {
		public var received = CoumpoundValue<Int64>()
		public var queued = CoumpoundValue<Int64>()
		public var sent = CoumpoundValue<Int64>()
		public var discarded = CoumpoundValue<Int64>()
	}

	open var writeTimeOut = 500.0
	open var statisticsWindow = 5	// Seconds
	open var statistics = Statistics()

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

    var bytesIn: Atomic<Int64> = .init(0)
    var bytesQueued: Atomic<Int64> = .init(0)
    var bytesOut: Atomic<Int64> = .init(0)
    var bytesDiscarded: Atomic<Int64> = .init(0)
	var timer : Timer?

    var queueBytesOut: Atomic<Int64> = .init(0)
    var totalBytesIn: Atomic<Int64> = .init(0)
    var totalBytesOut: Atomic<Int64> = .init(0)
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
    lazy var inputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.BlueSocket.input", qos: qualityOfService)
    lazy var outputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.BlueSocket.output", qos: qualityOfService)

    func connect(withName: String, port: Int) {
        handshake.clear()
        readyState = .uninitialized
        chunkSizeS = RTMPChunk.defaultSize
        chunkSizeC = RTMPChunk.defaultSize
        totalBytesIn.mutate { $0 = 0 }
        totalBytesOut.mutate { $0 = 0 }
        queueBytesOut.mutate { $0 = 0 }
        bytesIn.mutate { $0 = 0 }
        bytesQueued.mutate { $0 = 0 }
        bytesOut.mutate { $0 = 0 }
		bytesDiscarded.mutate { $0 = 0 }
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
		timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStats(timer:)), userInfo: nil, repeats: true)
    }

    func close(isDisconnected: Bool) {
        guard connection != nil else { return }
		timer?.invalidate()
		timer = nil
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
		let queuedAt = Date()
		bytesQueued.mutate { $0 += Int64(chunk.data.count) }
		outputQueue.async {
			let queuedFor = Date().timeIntervalSince(queuedAt)*1000
			guard queuedFor < self.writeTimeOut else {
				self.bytesDiscarded.mutate { $0 += Int64(chunk.data.count) }
				if logger.isEnabledFor(level: .trace) {
					logger.warn("discarded \(chunk.data.count) after \(Int(queuedFor))")
				}
				return
			}
			
			let chunks: [Data] = chunk.split(self.chunkSizeS)
			for i in 0..<chunks.count - 1 {
				self.send(data: chunks[i])
			}
			self.send(data: chunks.last!, locked: locked)
			self.bytesOut.mutate { $0 += Int64(chunk.data.count) }
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
			try self.connection?.write(from: data)
		} catch {
			print(error)
		}
		self.queueBytesOut.mutate { $0 -= Int64(data.count) }
		self.totalBytesOut.mutate { $0 += Int64(data.count) }
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
		self.bytesIn.mutate { $0 += Int64(data.count) }
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
	
	@objc func updateStats(timer: Timer) {
		let totalIn = bytesIn.mutate { $0 = 0 }
		let totalQueued = bytesQueued.mutate { $0 = 0 }
		let totalOut = bytesOut.mutate { $0 = 0 }
		let totalDiscarded = bytesDiscarded.mutate { $0 = 0 }
		statistics.received.add(totalIn, trim: statisticsWindow)
		statistics.queued.add(totalQueued, trim: statisticsWindow)
		statistics.sent.add(totalOut, trim: statisticsWindow)
		statistics.discarded.add(totalDiscarded, trim: statisticsWindow)
	}
}
