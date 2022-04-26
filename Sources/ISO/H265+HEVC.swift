//
//  H265+HEVC.swift
//  HaishinKit
//
//  Created by Guy on 14.04.22.
//  Copyright © 2022 Sporfie. All rights reserved.
//

import AVFoundation
import VideoToolbox

struct HEVCFormatStream {
	let data: Data

	init(data: Data) {
		self.data = data
	}

	init?(bytes: UnsafePointer<UInt8>, count: UInt32) {
		self.init(data: Data(bytes: bytes, count: Int(count)))
	}

	init?(data: Data?) {
		guard let data = data else {
			return nil
		}
		self.init(data: data)
	}

	func toByteStream() -> Data {
		let buffer = ByteArray(data: data)
		var result = Data()
		while 0 < buffer.bytesAvailable {
			do {
				let length: Int = try Int(buffer.readUInt32())
				result.append(contentsOf: [0x00, 0x00, 0x01])
				result.append(try buffer.readBytes(length))
			} catch {
				logger.error("\(buffer)")
			}
		}
		return result
	}
}

// MARK: -

struct HEVCArray {
	var arrayCompleteness: UInt8 = 0
	var NALUnitType: UInt8 = 0
	var nalus: [[UInt8]] = []
}

struct HEVCConfigurationRecord {
	static func getData(_ formatDescription: CMFormatDescription?) -> Data? {
		guard let formatDescription = formatDescription else { return nil }
		if let atoms: NSDictionary = CMFormatDescriptionGetExtension(formatDescription, extensionKey: "SampleDescriptionExtensionAtoms" as CFString) as? NSDictionary {
			return atoms["hvcC"] as? Data
		}
		return nil
	}

	var configurationVersion: UInt8 = 1
	var generalProfileSpace: UInt8 = 0
	var generalTierFlag: UInt8 = 0
	var generalProfileIDC: UInt8 = 0
	var generalProfileCompatibilityFlags: UInt32 = 0
	var generalConstraintIndicatorFlags: UInt64 = 0
	var generalLevelIDC: UInt8 = 0
	var minSpatialSegmentationIDC: UInt16 = 0
	var parallelismType: UInt8 = 0
	var chromaFormatIDC: UInt8 = 0
	var bitDepthLumaMinus8: UInt8 = 0
	var bitDepthChromaMinus8: UInt8 = 0
	var avgFrameRate: UInt16 = 0
	var constantFrameRate: UInt8 = 0
	var numTemporalLayers: UInt8 = 0
	var temporalIdNested: UInt8 = 0
	var lengthSizeMinusOne: UInt8 = 0
	var arrays: [HEVCArray] = []

	init() {
	}

	init(data: Data) {
		self.data = data
	}
}

extension HEVCConfigurationRecord: DataConvertible {
	// MARK: DataConvertible
	var data: Data {
		get {
			let buffer = ByteArray()
			buffer.writeUInt8(configurationVersion)
			buffer.writeUInt8((generalProfileSpace << 6) | (generalTierFlag << 5) | generalProfileIDC)
			buffer.writeUInt32(generalProfileCompatibilityFlags)
			buffer.writeUInt32(UInt32(generalConstraintIndicatorFlags >> 16))
			buffer.writeUInt16(UInt16(generalConstraintIndicatorFlags & 0xFFFF))
			buffer.writeUInt8(generalLevelIDC)
			buffer.writeUInt16(0xF000 | minSpatialSegmentationIDC)
			buffer.writeUInt8(0xFC | parallelismType)
			buffer.writeUInt8(0xFC | chromaFormatIDC)
			buffer.writeUInt8(0xF8 | bitDepthLumaMinus8)
			buffer.writeUInt8(0xF8 | bitDepthChromaMinus8)
			buffer.writeUInt16(avgFrameRate)
			buffer.writeUInt8((constantFrameRate << 6) | (numTemporalLayers << 3) | (temporalIdNested << 2) | lengthSizeMinusOne)
			buffer.writeUInt8(UInt8(arrays.count))
			for array in arrays {
				buffer.writeUInt8((array.arrayCompleteness << 7) | (array.NALUnitType & 0x3F))
				buffer.writeUInt16(UInt16(array.nalus.count))
				for nalu in array.nalus {
					buffer.writeUInt16(UInt16(nalu.count))
					buffer.writeBytes(Data(nalu))
				}
			}
			return buffer.data
		}
		set {
			let buffer = ByteArray(data: newValue)
			do {
				configurationVersion = try buffer.readUInt8()
				var tmp = try buffer.readUInt8()
				generalProfileSpace = tmp >> 6
				generalTierFlag = (tmp >> 5) & 0x01
				generalProfileIDC = tmp & 0x1F
				generalProfileCompatibilityFlags = try buffer.readUInt32()
				let tmp32 = try buffer.readUInt32()
				let tmp16 = try buffer.readUInt16()
				generalConstraintIndicatorFlags = (UInt64(tmp32) << 16) | UInt64(tmp16)
				generalLevelIDC = try buffer.readUInt8()
				minSpatialSegmentationIDC = try buffer.readUInt16() & 0xFFF
				tmp = try buffer.readUInt8()
				parallelismType = tmp & 0x03
				chromaFormatIDC = try buffer.readUInt8() & 0x03
				bitDepthLumaMinus8 = try buffer.readUInt8() & 0x07
				bitDepthChromaMinus8 = try buffer.readUInt8() & 0x07
				avgFrameRate = try buffer.readUInt16()
				tmp = try buffer.readUInt8()
				constantFrameRate = tmp >> 6
				numTemporalLayers = (tmp >> 3) & 0x07
				temporalIdNested = (tmp >> 2) & 0x01
				lengthSizeMinusOne = tmp & 0x03
				let numOfArrays = try buffer.readUInt8()
				for _ in 0..<numOfArrays {
					var array = HEVCArray()
					let tmp = try buffer.readUInt8()
					array.arrayCompleteness = tmp >> 7
					array.NALUnitType = tmp & 0x3F
					let numNALUs = try buffer.readUInt16()
					for _ in 0..<numNALUs {
						let nalUnitLength = try buffer.readUInt16()
						let nalu = try buffer.readBytes(Int(nalUnitLength))
						array.nalus.append(nalu.bytes)
					}
					arrays.append(array)
				}
			} catch {
				logger.error("\(buffer)")
			}
		}
	}
}

extension HEVCConfigurationRecord: CustomDebugStringConvertible {
	// MARK: CustomDebugStringConvertible
	var debugDescription: String {
		Mirror(reflecting: self).debugDescription
	}
}
