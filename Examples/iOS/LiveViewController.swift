import AVFoundation
import HaishinKit
import Photos
import UIKit
import VideoToolbox

final class ExampleRecorderDelegate: DefaultAVRecorderDelegate {
    static let `default` = ExampleRecorderDelegate()

    override func didFinishWriting(_ recorder: AVRecorder) {
        guard let writer: AVAssetWriter = recorder.writer else {
            return
        }
        PHPhotoLibrary.shared().performChanges({() -> Void in
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: writer.outputURL)
        }, completionHandler: { _, error -> Void in
            do {
                try FileManager.default.removeItem(at: writer.outputURL)
            } catch {
                print(error)
            }
        })
    }
}

final class LiveViewController: UIViewController, RTMPStreamDelegate {
    private static let maxRetryCount: Int = 5

    @IBOutlet private weak var lfView: MTHKView!
    @IBOutlet private weak var currentFPSLabel: UILabel!
    @IBOutlet private weak var publishButton: UIButton!
    @IBOutlet private weak var pauseButton: UIButton!
    @IBOutlet private weak var videoBitrateLabel: UILabel!
    @IBOutlet private weak var videoBitrateSlider: UISlider!
    @IBOutlet private weak var audioBitrateLabel: UILabel!
    @IBOutlet private weak var zoomSlider: UISlider!
    @IBOutlet private weak var audioBitrateSlider: UISlider!
    @IBOutlet private weak var fpsControl: UISegmentedControl!
    @IBOutlet private weak var effectSegmentControl: UISegmentedControl!

    private var rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream!
	private var srtSocket = SRTSocket()
	private var srtStream: SRTStream!
	private var stream: NetStream!
    private var sharedObject: RTMPSharedObject!
    private var currentEffect: VideoEffect?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var retryCount: Int = 0
	let useSRT = Preference.defaultInstance.uri!.starts(with: "srt://")
	var watchingSRTStats = false

    override func viewDidLoad() {
        super.viewDidLoad()

		if useSRT {
			srtStream = SRTStream(url: URL(string: Preference.defaultInstance.uri!)!)
			stream = srtStream
		} else {
			rtmpConnection.networkServiceType = .video
			rtmpStream = RTMPStream(connection: rtmpConnection)
			rtmpStream.delegate = self
			stream = rtmpStream
		}
		
		if let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
			stream.orientation = orientation
		}
		stream.mixer.recorder.delegate = ExampleRecorderDelegate.shared
		stream.captureSettings = [
			.sessionPreset: AVCaptureSession.Preset.hd1280x720,
			.continuousAutofocus: true,
			.continuousExposure: true
			// .preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode.auto
		]
		stream.videoSettings = [
			.width: 720,
			.height: 1280
		]

        videoBitrateSlider?.value = Float(RTMPStream.defaultVideoBitrate) / 1000
        audioBitrateSlider?.value = Float(RTMPStream.defaultAudioBitrate) / 1000

        NotificationCenter.default.addObserver(self, selector: #selector(on(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        logger.info("viewWillAppear")
        super.viewWillAppear(animated)
        stream.attachAudio(AVCaptureDevice.default(for: .audio)) { error in
            logger.warn(error.description)
        }
        stream.attachCamera(DeviceUtil.device(withPosition: currentPosition)) { error in
            logger.warn(error.description)
        }
        stream.addObserver(self, forKeyPath: "currentFPS", options: .new, context: nil)
		lfView?.attachStream(stream)
    }

    override func viewWillDisappear(_ animated: Bool) {
        logger.info("viewWillDisappear")
        super.viewWillDisappear(animated)
		stream.removeObserver(self, forKeyPath: "currentFPS")
		stream.close()
		stream.dispose()
    }

    @IBAction func rotateCamera(_ sender: UIButton) {
        logger.info("rotateCamera")
        let position: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
		stream.captureSettings[.isVideoMirrored] = position == .front
		stream.attachCamera(DeviceUtil.device(withPosition: position)) { error in
            logger.warn(error.description)
        }
        currentPosition = position
    }

    @IBAction func toggleTorch(_ sender: UIButton) {
		stream.torch.toggle()
    }

    @IBAction func on(slider: UISlider) {
        if slider == audioBitrateSlider {
            audioBitrateLabel?.text = "audio \(Int(slider.value))/kbps"
			stream.audioSettings[.bitrate] = slider.value * 1000
        }
        if slider == videoBitrateSlider {
            videoBitrateLabel?.text = "video \(Int(slider.value))/kbps"
			stream.videoSettings[.bitrate] = slider.value * 1000
        }
        if slider == zoomSlider {
			stream.setZoomFactor(CGFloat(slider.value), ramping: true, withRate: 5.0)
        }
    }

    @IBAction func on(pause: UIButton) {
		(stream as? RTMPStream)?.paused.toggle()
    }

    @IBAction func on(close: UIButton) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func on(publish: UIButton) {
        if publish.isSelected {
            UIApplication.shared.isIdleTimerDisabled = false
			if useSRT {
				srtStream.close()
				watchingSRTStats = false
			} else {
				rtmpConnection.close()
				rtmpConnection.removeEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
				rtmpConnection.removeEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
			}
            publish.setTitle("●", for: [])
        } else {
            UIApplication.shared.isIdleTimerDisabled = true
			if useSRT {
				srtStream.publish()
				watchingSRTStats = true
				watchSRTStats()
			} else {
				rtmpConnection.addEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
				rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
				rtmpConnection.connect(Preference.defaultInstance.uri!)
			}
            publish.setTitle("■", for: [])
        }
        publish.isSelected.toggle()
    }
	
	func watchSRTStats() {
		guard self.watchingSRTStats else { return }
		let stats = srtStream.socket.stats
		print("SRT stats: \(stats)")
		DispatchQueue.main.asyncAfter(deadline: .now()+1) {
			self.watchSRTStats()
		}
	}
		
    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        logger.info(code)
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            retryCount = 0
			(stream as? RTMPStream)?.publish(Preference.defaultInstance.streamName!)
            // sharedObject!.connect(rtmpConnection)
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retryCount <= LiveViewController.maxRetryCount else {
                return
            }
            Thread.sleep(forTimeInterval: pow(2.0, Double(retryCount)))
            rtmpConnection.connect(Preference.defaultInstance.uri!)
            retryCount += 1
        default:
            break
        }
    }

    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        logger.error(notification)
//        rtmpConnection.connect(Preference.defaultInstance.uri!)
    }

    func tapScreen(_ gesture: UIGestureRecognizer) {
        if let gestureView = gesture.view, gesture.state == .ended {
            let touchPoint: CGPoint = gesture.location(in: gestureView)
            let pointOfInterest = CGPoint(x: touchPoint.x / gestureView.bounds.size.width, y: touchPoint.y / gestureView.bounds.size.height)
            print("pointOfInterest: \(pointOfInterest)")
			stream.setPointOfInterest(pointOfInterest, exposure: pointOfInterest)
        }
    }

    @IBAction private func onFPSValueChanged(_ segment: UISegmentedControl) {
        switch segment.selectedSegmentIndex {
        case 0:
			stream.captureSettings[.fps] = 15.0
        case 1:
			stream.captureSettings[.fps] = 30.0
        case 2:
			stream.captureSettings[.fps] = 60.0
        default:
            break
        }
    }

    @IBAction private func onEffectValueChanged(_ segment: UISegmentedControl) {
        if let currentEffect: VideoEffect = currentEffect {
            _ = stream.unregisterVideoEffect(currentEffect)
        }
        switch segment.selectedSegmentIndex {
        case 1:
            currentEffect = MonochromeEffect()
            _ = stream.registerVideoEffect(currentEffect!)
        case 2:
            currentEffect = PronamaEffect()
            _ = stream.registerVideoEffect(currentEffect!)
        default:
            break
        }
    }

    @objc
    private func on(_ notification: Notification) {
        guard let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) else {
            return
        }
		stream.orientation = orientation
    }

    @objc
    private func didEnterBackground(_ notification: Notification) {
        // stream.receiveVideo = false
    }

    @objc
    private func didBecomeActive(_ notification: Notification) {
        // stream.receiveVideo = true
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if Thread.isMainThread {
			if let rtmp = stream as? RTMPStream {
				currentFPSLabel?.text = "\(rtmp.currentFPS)"
			}
        }
    }
	
	func rtmpStream(_ stream: RTMPStream, didPublishInsufficientBW connection: RTMPConnection) {
		if let stats = connection.socketStatistics {
			let sent = Double(stats.sent.total)
			let discarded = Double(stats.discarded.total)
			let prct = 100*discarded/(discarded+sent)
			let queued = stats.queued.total-stats.sent.total
			print("Insufficient bandwidth, packet loss \(prct)%, in queue \(queued)")
		}
	}
	
	func rtmpStream(_ stream: RTMPStream, didPublishSufficientBW connection: RTMPConnection) {
//		NSLog("didPublishSufficientBW")
	}
	
	func rtmpStream(_ stream: RTMPStream, didOutput audio: AVAudioBuffer, presentationTimeStamp: CMTime) {
		//		NSLog("didOutput audio")
	}
	
	func rtmpStream(_ stream: RTMPStream, didOutput video: CMSampleBuffer) {
		//		NSLog("didOutput video")
	}
	
	func rtmpStream(_ stream: RTMPStream, didStatics connection: RTMPConnection) {
		//		NSLog("didStatics")
	}
	
	func rtmpStreamDidClear(_ stream: RTMPStream) {
		//		NSLog("didClear")
	}
}
