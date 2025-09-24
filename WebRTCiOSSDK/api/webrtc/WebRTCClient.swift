//
//  WebRTCClient.swift
//  AntMediaSDK
//
//  Copyright © 2018 AntMedia. All rights reserved.
//

import Foundation
import AVFoundation
import WebRTC
import ReplayKit

// MARK: - Camera Mode Enum
public enum CameraMode {
    case frontOnly
    case backOnly
    case dualCamera
}

class WebRTCClient: NSObject {
    
    let VIDEO_TRACK_ID = "VIDEO"
    let AUDIO_TRACK_ID = "AUDIO"
    let LOCAL_MEDIA_STREAM_ID = "STREAM"
    
    private var audioDeviceModule: RTCAudioDeviceModule?
    
    private var factory: RTCPeerConnectionFactory
    
    weak var delegate: WebRTCClientDelegate?
    
    var peerConnection: RTCPeerConnection?
    
    private var videoCapturer: RTCVideoCapturer?
    var localVideoTrack: RTCVideoTrack!
    var localAudioTrack: RTCAudioTrack!
    var remoteVideoTrack: RTCVideoTrack!
    var remoteAudioTrack: RTCAudioTrack!
    var remoteVideoView: RTCVideoRenderer?
    var localVideoView: RTCVideoRenderer?
    var videoSender: RTCRtpSender?
    var dataChannel: RTCDataChannel?
    
    // MARK: - Dual Camera Support
    private var cameraMode: CameraMode = .frontOnly
    
    @available(iOS 13.0, *)
    var multiCamSession: AVCaptureMultiCamSession? { // use this as a getter for what you want
       return _multiCamSession as? AVCaptureMultiCamSession
    }
    
    private var _multiCamSession: Any?
    
    private var frontVideoCapturer: RTCCameraVideoCapturer?
    private var backVideoCapturer: RTCCameraVideoCapturer?
    private var frontVideoTrack: RTCVideoTrack?
    private var backVideoTrack: RTCVideoTrack?
    private var frontVideoSender: RTCRtpSender?
    private var backVideoSender: RTCRtpSender?
    
    // Session management for dual camera
    private var frontCameraSession: AVCaptureSession?
    private var backCameraSession: AVCaptureSession?
    private var sessionQueue: DispatchQueue = DispatchQueue(label: "camera.session.queue")
    
    private var token: String!
    private var streamId: String!
    
    private var audioEnabled: Bool = true
    private var videoEnabled: Bool = true
    
    private var frameRenderer: FrameRenderer?
    
    // Timer for sending timestamp messages
    private var timestampTimer: Timer?
    
    /**
     If useExternalCameraSource is false, it opens the local camera
     If it's true, it does not open the local camera. When it's set to true, it can record the screen in-app or you can give external frames through your application or BroadcastExtension. If you give external frames or through BroadcastExtension, you need to set the externalVideoCapture to true as well
     */
    private var useExternalCameraSource: Bool = false
    
    private var enableDataChannel: Bool = false
    
    private var cameraPosition: AVCaptureDevice.Position = .front
    
    private var targetWidth: Int = 480
    private var targetHeight: Int = 360
    
    private var externalVideoCapture: Bool = false
    
    private var externalAudio: Bool = false
    
    private var cameraSourceFPS: Int = 30
    
    /*
     State of the connection
     */
    var iceConnectionState: RTCIceConnectionState = .new
    
    private var degradationPreference: RTCDegradationPreference = .maintainResolution
    
    private var photoOutput: AVCapturePhotoOutput?

    public var minimumZoom: CGFloat = 1.0
    public var maximumZoom: CGFloat = 15.0
    public var lastZoomFactor: CGFloat = 1.0
    
    // this is not an ideal method to get current capture device, we need more legit solution
    var captureDevice: AVCaptureDevice? {
        if videoEnabled {
           return getDefaultCameraDevice(with: cameraPosition)
        }
        else {
          return nil;
        }
    }
    
    // MARK: - Dual Camera Support Methods
    
    /// Check if device supports multi-camera capture
    @available(iOS 15.0, *)
    public static func isMultiCamSupported() -> Bool {
        return AVCaptureMultiCamSession.isMultiCamSupported
    }
    
    /// Set camera mode
    @available(iOS 15.0, *)
    public func setCameraMode(_ mode: CameraMode) {
        self.cameraMode = mode
        
        switch mode {
        case .frontOnly:
            self.cameraPosition = .front
        case .backOnly:
            self.cameraPosition = .back
        case .dualCamera:
            self.cameraPosition = .front // Default for dual camera
        }
    }
    
    /// Get current camera mode
    @available(iOS 15.0, *)
    public func getCameraMode() -> CameraMode {
        return self.cameraMode
    }
    
    var _currentCaptureDevice: AVCaptureDevice?

    public init(remoteVideoView: RTCVideoRenderer?, localVideoView: RTCVideoRenderer?, delegate: WebRTCClientDelegate, externalAudio: Bool) {
        RTCInitializeSSL()
        
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        
        self.externalAudio = externalAudio
        self.audioDeviceModule = RTCAudioDeviceModule()
        self.audioDeviceModule?.setExternalAudio(externalAudio)
        
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory,
            audioDeviceModule: audioDeviceModule!
        )
        
        super.init()
        
        self.remoteVideoView = remoteVideoView
        self.localVideoView = localVideoView
        self.delegate = delegate
        
        let stunServer = Config.defaultStunServer()
        let defaultConstraint = Config.createDefaultConstraint()
        let configuration = Config.createConfiguration(server: stunServer)
        
        self.peerConnection = factory.peerConnection(with: configuration, constraints: defaultConstraint, delegate: self)
    }
    
    public convenience init(
        remoteVideoView: RTCVideoRenderer?,
        localVideoView: RTCVideoRenderer?,
        delegate: WebRTCClientDelegate,
        cameraPosition: AVCaptureDevice.Position,
        targetWidth: Int,
        targetHeight: Int,
        streamId: String
    ) {
        self.init(remoteVideoView: remoteVideoView,
                  localVideoView: localVideoView,
                  delegate: delegate,
                  cameraPosition: cameraPosition,
                  targetWidth: targetWidth,
                  targetHeight: targetHeight,
                  videoEnabled: true,
                  enableDataChannel: false,
                  streamId: streamId
        )
    }
    
    // MARK: - New Init with Camera Mode Support
    @available(iOS 15.0, *)
    public convenience init(
        remoteVideoView: RTCVideoRenderer?,
        localVideoView: RTCVideoRenderer?,
        delegate: WebRTCClientDelegate,
        cameraMode: CameraMode,
        targetWidth: Int,
        targetHeight: Int,
        streamId: String
    ) {
        self.init(remoteVideoView: remoteVideoView,
                  localVideoView: localVideoView,
                  delegate: delegate,
                  cameraPosition: .front, // Will be set based on cameraMode
                  targetWidth: targetWidth,
                  targetHeight: targetHeight,
                  videoEnabled: true,
                  enableDataChannel: false,
                  useExternalCameraSource: false,
                  streamId: streamId
        )
        
        self.cameraMode = cameraMode
        
        // Set camera position based on mode
        switch cameraMode {
        case .frontOnly:
            self.cameraPosition = .front
        case .backOnly:
            self.cameraPosition = .back
        case .dualCamera:
            self.cameraPosition = .front // Default for dual camera
        }
    }
    
    public convenience init(
        remoteVideoView: RTCVideoRenderer?,
        localVideoView: RTCVideoRenderer?,
        delegate: WebRTCClientDelegate,
        cameraPosition: AVCaptureDevice.Position,
        targetWidth: Int,
        targetHeight: Int,
        videoEnabled: Bool,
        enableDataChannel: Bool,
        streamId: String
    ) {
        self.init(remoteVideoView: remoteVideoView,
                  localVideoView: localVideoView,
                  delegate: delegate,
                  cameraPosition: cameraPosition,
                  targetWidth: targetWidth,
                  targetHeight: targetHeight,
                  videoEnabled: true,
                  enableDataChannel: false,
                  useExternalCameraSource: false,
                  streamId: streamId
        )
    }
    
    public convenience init(
        remoteVideoView: RTCVideoRenderer?,
        localVideoView: RTCVideoRenderer?,
        delegate: WebRTCClientDelegate,
        cameraPosition: AVCaptureDevice.Position,
        targetWidth: Int,
        targetHeight: Int,
        videoEnabled: Bool,
        enableDataChannel: Bool,
        useExternalCameraSource: Bool,
        externalAudio: Bool = false,
        externalVideoCapture: Bool = false,
        cameraSourceFPS: Int = 30,
        streamId: String,
        degradationPreference: RTCDegradationPreference = .maintainResolution
    ) {
        
        self.init(remoteVideoView: remoteVideoView, localVideoView: localVideoView, delegate: delegate, externalAudio: externalAudio)
        self.cameraPosition = cameraPosition
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.videoEnabled = videoEnabled
        self.useExternalCameraSource = useExternalCameraSource
        self.enableDataChannel = enableDataChannel
        self.externalVideoCapture = externalVideoCapture
        self.cameraSourceFPS = cameraSourceFPS
        self.streamId = streamId
        self.degradationPreference = degradationPreference
    }
    
    public func externalVideoCapture(externalVideoCapture: Bool) {
        self.externalVideoCapture = externalVideoCapture
    }
    
    private func initFactory() -> RTCPeerConnectionFactory {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        
        if audioDeviceModule == nil {
            return RTCPeerConnectionFactory(
                encoderFactory: videoEncoderFactory,
                decoderFactory: videoDecoderFactory
            )
        } else {
            return RTCPeerConnectionFactory(
                encoderFactory: videoEncoderFactory,
                decoderFactory: videoDecoderFactory,
                audioDeviceModule: audioDeviceModule!
            )
        }
    }
    
    public func setMaxVideoBps(maxVideoBps: NSNumber) {
        print("In setMaxVideoBps:\(maxVideoBps)")
        if maxVideoBps.intValue > 0 {
            print("setMaxVideoBps:\(maxVideoBps)")
            self.peerConnection?.setBweMinBitrateBps(nil, currentBitrateBps: nil, maxBitrateBps: maxVideoBps)
        }
    }
    
    public func getStats(handler: @escaping (RTCStatisticsReport) -> Void) {
        self.peerConnection?.statistics(completionHandler: handler)
    }
    
    public func setStreamId(_ streamId: String) {
        self.streamId = streamId
    }
    
    public func setToken(_ token: String) {
        self.token = token
    }
    
    public func setRemoteDescription(_ description: RTCSessionDescription, completionHandler: @escaping RTCSetSessionDescriptionCompletionHandler) {
        self.peerConnection?.setRemoteDescription(description, completionHandler: completionHandler)
    }
    
    public func addCandidate(_ candidate: RTCIceCandidate) {
        self.peerConnection?.add(candidate)
    }
    
    public func sendData(data: Data, binary: Bool = false) {
        if self.dataChannel?.readyState == .open {
            let dataBuffer = RTCDataBuffer(data: data, isBinary: binary)
            self.dataChannel?.sendData(dataBuffer)
        } else {
            print("Data channel is nil or state is not open. State is \(String(describing: self.dataChannel?.readyState)) Please check that data channel is enabled in server side ")
        }
    }
    

    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        // Make sure you have already initialized the remoteVideoTrack from the WebRTC video call.

        if frameRenderer == nil {
            frameRenderer = FrameRenderer(uID: 1)
        }

        self.remoteVideoTrack?.add(frameRenderer!)
    }
    
    func removeRenderRemoteVideo(to renderer: RTCVideoRenderer) {
        if frameRenderer != nil {
            self.remoteVideoTrack?.remove(frameRenderer!)
        }
    }

    public func isDataChannelActive() -> Bool {
        return self.dataChannel?.readyState == .open
    }
    
    private func addCapturePhotoOutput() {
        let capturePhotoOutput = AVCapturePhotoOutput()
        let videoCapturer = self.videoCapturer as? RTCCameraVideoCapturer
        if videoCapturer?.captureSession.canAddOutput(capturePhotoOutput) == true {
            videoCapturer?.captureSession.addOutput(capturePhotoOutput)
            self.photoOutput = capturePhotoOutput
        }
    }
    
    public func didTappedCapturePhoto() {
        // Photo capture only from back camera
        guard _currentCaptureDevice != nil else { return }
        
        let settings = AVCapturePhotoSettings()
        guard let previewPixelType = settings.availablePreviewPhotoPixelFormatTypes.first else { return }
        
        let screenSize = UIScreen.main.bounds.size
        let previewFormat: [String : Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: previewPixelType,
            kCVPixelBufferWidthKey as String: screenSize.width,
            kCVPixelBufferHeightKey as String: screenSize.height
        ]
        
        settings.previewPhotoFormat = previewFormat
        photoOutput?.capturePhoto(with: settings, delegate: self)
    }
    
    private func loadImage(data: Data) {
        guard let dataProvider = CGDataProvider(data: data as CFData),
              let cgImageRef: CGImage = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        let image = UIImage(cgImage: cgImageRef, scale: 1.0, orientation: .right)
        delegate?.didCameraCapturedPhoto(capturedPhoto: image)
    }
    
    public func sendAnswer() {
        let constraint = Config.createAudioVideoConstraints()
        self.peerConnection?.answer(for: constraint, completionHandler: { sdp, error in
            if error != nil {
                print("Error (sendAnswer): " + error!.localizedDescription)
            } else {
                print("Got your answer")
                if sdp?.type == RTCSdpType.answer {
                    self.peerConnection?.setLocalDescription(sdp!, completionHandler: { error in
                        if error != nil {
                            print("Error (sendAnswer/closure): " + error!.localizedDescription)
                        }
                    })
                    
                    var answerDict = [String: Any]()
                    
                    if self.token.isEmpty {
                        answerDict = ["type": "answer",
                                      "command": "takeConfiguration",
                                      "sdp": sdp!.sdp,
                                      "streamId": self.streamId!] as [String: Any]
                    } else {
                        answerDict = ["type": "answer",
                                      "command": "takeConfiguration",
                                      "sdp": sdp!.sdp,
                                      "streamId": self.streamId!,
                                      "token": self.token] as [String: Any]
                    }
                    
                    self.delegate?.sendMessage(answerDict)
                }
            }
        })
    }
    
    public func createOffer() {
        
        // let the one who creates offer also create data channel.
        // by doing that it will work both in publish-play and peer-to-peer mode
        if enableDataChannel {
            self.dataChannel = createDataChannel()
            self.dataChannel?.delegate = self
        }
        
        let constraint = Config.createAudioVideoConstraints()
        
        self.peerConnection?.offer(for: constraint, completionHandler: { sdp, error in
            if sdp?.type == RTCSdpType.offer {
                print("Got your offer")
                
                self.peerConnection?.setLocalDescription(sdp!, completionHandler: { error in
                    if error != nil {
                        print("Error (createOffer): " + error!.localizedDescription)
                    }
                })
                
                print("offer sdp: " + sdp!.sdp)
                var offerDict = [String: Any]()
                
                if self.token.isEmpty {
                    offerDict = ["type": "offer",
                                 "command": "takeConfiguration",
                                 "sdp": sdp!.sdp,
                                 "streamId": self.streamId!] as [String: Any]
                } else {
                    offerDict = ["type": "offer",
                                 "command": "takeConfiguration",
                                 "sdp": sdp!.sdp,
                                 "streamId": self.streamId!,
                                 "token": self.token] as [String: Any]
                }
                
                self.delegate?.sendMessage(offerDict)
            }
        })
    }
    
    public func stop() {
        disconnect()
    }
    
    private func createDataChannel() -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        guard let dataChannel = self.peerConnection?.dataChannel(forLabel: "WebRTCData", configuration: config) else {
            print("Warning: Couldn't create data channel.")
            return nil
        }
        return dataChannel
    }
    
    public func disconnect() {
        print("disconnecting and releasing resources for \(streamId)")
        
        // Timer'ı durdur
        stopSendTimestamp()
        
        if let view = self.localVideoView {
            self.localVideoTrack?.remove(view)
        }
        
        if let view = self.remoteVideoView {
            self.remoteVideoTrack?.remove(view)
            removeRenderRemoteVideo(to: view)
        }
        
        self.remoteVideoView?.renderFrame(nil)
        self.localVideoTrack = nil
        self.remoteVideoTrack = nil
        
        if self.videoCapturer is RTCCameraVideoCapturer {
            (self.videoCapturer as? RTCCameraVideoCapturer)?.stopCapture()
        } else if self.videoCapturer is RTCCustomFrameCapturer {
            (self.videoCapturer as? RTCCustomFrameCapturer)?.stopCapture()
        }
        
        // Stop dual camera capturers if they exist
        if #available(iOS 15.0, *) {
            cleanupDualCameraResources()
        }
        
        self.videoCapturer = nil
        
        self.peerConnection?.close()
        self.peerConnection = nil
        print("disconnected and released resources for \(streamId)")
    }
    
    public func sendTimestamp() {
        guard timestampTimer == nil else {
            print("Timestamp timer is already running")
            return
        }
        
        // İlk timestamp'i hemen gönder
        sendSingleTimestamp()
        
        // Timer'ı başlat
        timestampTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendSingleTimestamp()
        }
    }
    
    private func sendSingleTimestamp() {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let notif = [
            EVENT_TYPE: "frame-ts",
            TIMESTAMP: ts,
        ].json
        
        if dataChannel == nil {
            dataChannel = createDataChannel()
            dataChannel?.delegate = self
        }
        
        if let data = notif.data(using: .utf8) {
            sendData(data: data)
        }
        
        
        print("Sent timestamp: \(ts)")
    }
    
    public func stopSendTimestamp() {
        // Timer'ı durdur ve temizle
        timestampTimer?.invalidate()
        timestampTimer = nil
        
        // Data channel'ı temizle
        if dataChannel != nil {
            dataChannel = nil
        }
        
        print("Stopped sending timestamps")
    }

    public func toggleAudioEnabled() {
        self.setAudioEnabled(enabled: !self.audioEnabled)
    }
    
    public func setAudioEnabled(enabled: Bool) {
        self.audioEnabled = enabled
        if self.localAudioTrack != nil {
            self.localAudioTrack.isEnabled = self.audioEnabled
        }
    }
    
    public func isAudioEnabled() -> Bool {
        return self.audioEnabled
    }
    
    public func toggleVideoEnabled() {
        self.setVideoEnabled(enabled: !self.videoEnabled)
    }
    
    func isVideoEnabled() -> Bool {
        return self.videoEnabled
    }
    
    public func setVideoEnabled(enabled: Bool) {
        self.videoEnabled = enabled
        
        if self.localVideoTrack != nil {
            self.localVideoTrack.isEnabled = self.videoEnabled
        }
    }
    
    public func getIceConnectionState() -> RTCIceConnectionState {
        return iceConnectionState
    }
    
    @discardableResult
    private func startCapture() -> Bool {
        if captureDevice != nil {
            let supportedFormats = RTCCameraVideoCapturer.supportedFormats(for: captureDevice!)
            
            var currentDiff = INT_MAX
            
            var selectedFormat: AVCaptureDevice.Format?
            
            for supportedFormat in supportedFormats {
                let dimension = CMVideoFormatDescriptionGetDimensions(supportedFormat.formatDescription)
                let diff = abs(Int32(targetWidth) - dimension.width) + abs(Int32(targetHeight) - dimension.height)
                if diff < currentDiff {
                    selectedFormat = supportedFormat
                    currentDiff = diff
                }
            }
            
            if selectedFormat != nil {
                var maxSupportedFramerate: Float64 = 0
                for fpsRange in selectedFormat!.videoSupportedFrameRateRanges {
                    maxSupportedFramerate = fmax(maxSupportedFramerate, fpsRange.maxFrameRate)
                }
                let fps = fmin(maxSupportedFramerate, Double(self.cameraSourceFPS))
                
                let dimension = CMVideoFormatDescriptionGetDimensions(selectedFormat!.formatDescription)
                
                print("Camera resolution: " + String(dimension.width) + "x" + String(dimension.height)
                                      + " fps: " + String(fps))
                
                let cameraVideoCapturer = self.videoCapturer as? RTCCameraVideoCapturer
                                
                cameraVideoCapturer?.startCapture(with: _currentCaptureDevice ?? captureDevice!,
                                                  format: selectedFormat!,
                                                  fps: Int(fps))
                                
                return true
            } else {
                print("Cannot open camera not suitable format")
            }
        } else {
            print("Not Camera Found")
        }
        
        return false
    }
    
    func setDefaultCameraZoomFactorIfNeeded() {
        if #available(iOS 15.0, *) {
            guard let camera = _currentCaptureDevice else { return }
            
            if camera.deviceType == .builtInUltraWideCamera || camera.deviceType == .builtInTripleCamera {
                do {
                    try _currentCaptureDevice?.lockForConfiguration()
                    _currentCaptureDevice?.videoZoomFactor = 1.5
                    _currentCaptureDevice?.unlockForConfiguration()
                } catch {
                    print("couldn't set video zoom factor to 1.5")
                }
            }
        }
    }
    
    
    private func getDefaultCameraDevice(with position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if #available(iOS 13.0, *) {
            let deviceName = UIDevice.type.rawValue
            let shouldDeviceStartWithUltraWide = UIDevice
                .devicesThatShouldStartWithUltraWide
                .map { $0.rawValue }
                .contains(deviceName)
            
            var captureDevice: AVCaptureDevice?
            
            if AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position) != nil {
                if shouldDeviceStartWithUltraWide,
                   let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) {
                    lastZoomFactor = 1.5
                    minimumZoom = 1.5
                    maximumZoom = device.maxAvailableVideoZoomFactor
                    captureDevice = device
                } else if UIDevice.type == .iPhone14Pro || UIDevice.type == .iPhone14ProMax || UIDevice.type == .iPhone15Pro || UIDevice.type == .iPhone15ProMax || UIDevice.type == .unrecognized,
                          let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position) {
                    lastZoomFactor = 1.5
                    minimumZoom = 1.5
                    maximumZoom = device.maxAvailableVideoZoomFactor
                    captureDevice = device
                } else if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
                    lastZoomFactor = 1.0
                    minimumZoom = 1.0
                    maximumZoom = device.maxAvailableVideoZoomFactor
                    captureDevice = device
                }
            } else {
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
                    lastZoomFactor = 1.0
                    minimumZoom = 1.0
                    maximumZoom = device.maxAvailableVideoZoomFactor
                    captureDevice = device
                }
            }
            self._currentCaptureDevice = captureDevice
            return captureDevice
        }
        return (RTCCameraVideoCapturer.captureDevices().first { $0.position == self.cameraPosition })
    }

    private func createVideoTrack() -> RTCVideoTrack? {
        if useExternalCameraSource {
            // try with screencast video source
            let videoSource = factory.videoSource(forScreenCast: true)
            
            self.videoCapturer = RTCCustomFrameCapturer(
                delegate: videoSource,
                height: targetHeight,
                externalCapture: externalVideoCapture,
                videoEnabled: videoEnabled,
                audioEnabled: externalAudio,
                fps: self.cameraSourceFPS
            )
            
            (self.videoCapturer as? RTCCustomFrameCapturer)?.setWebRTCClient(webRTCClient: self)
            (self.videoCapturer as? RTCCustomFrameCapturer)?.startCapture()
            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            return videoTrack
        } else {
            let videoSource = factory.videoSource()
            #if TARGET_OS_SIMULATOR
            self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
            #else
            
            self.videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
            addCapturePhotoOutput()
            
            let captureStarted = startCapture()
            if !captureStarted {
                return nil
            }
            #endif
            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            return videoTrack
        }
    }
    
    // MARK: - Dual Camera Video Track Creation
    
    /// Create dual camera video tracks
    @available(iOS 15.0, *)
    private func createDualCameraVideoTracks() -> (frontTrack: RTCVideoTrack?, backTrack: RTCVideoTrack?) {
        guard WebRTCClient.isMultiCamSupported() else {
            print("Multi-camera not supported on this device")
            return (nil, nil)
        }
        
        // Use sequential camera setup to avoid session conflicts
        return sessionQueue.sync {
            // Create front camera track first
            let frontVideoSource = factory.videoSource()
            self.frontVideoCapturer = RTCCameraVideoCapturer(delegate: frontVideoSource)
            self.frontVideoTrack = factory.videoTrack(with: frontVideoSource, trackId: "front_video")
            
            // Start front camera capture
            guard startFrontCameraCapture() else {
                print("Failed to start front camera capture")
                return (nil, nil)
            }
            
            // Add delay to ensure front camera is fully initialized
            Thread.sleep(forTimeInterval: 0.1)
            
            // Create back camera track
            let backVideoSource = factory.videoSource()
            self.backVideoCapturer = RTCCameraVideoCapturer(delegate: backVideoSource)
            self.backVideoTrack = factory.videoTrack(with: backVideoSource, trackId: "back_video")
            
            // Start back camera capture
            guard startBackCameraCapture() else {
                print("Failed to start back camera capture")
                // Clean up front camera if back camera fails
                self.frontVideoCapturer?.stopCapture()
                return (nil, nil)
            }
            
            print("Dual camera setup completed successfully")
            return (self.frontVideoTrack, self.backVideoTrack)
        }
    }
    
    /// Start front camera capture
    @available(iOS 15.0, *)
    private func startFrontCameraCapture() -> Bool {
        print("Starting front camera capture...")
        guard let frontCapturer = frontVideoCapturer else {
            print("Front capturer is nil")
            return false
        }
        
        // Get front camera device
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            print("Could not get front camera")
            return false
        }
        
        print("Front camera device found: \(frontCamera.localizedName)")
        
        // Check if camera is available for use
        do {
            try frontCamera.lockForConfiguration()
            frontCamera.unlockForConfiguration()
        } catch {
            print("Front camera is not available: \(error)")
            return false
        }
        
        // Start capture with front camera
        let supportedFormats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
        var selectedFormat: AVCaptureDevice.Format?
        var currentDiff = INT_MAX
        
        for supportedFormat in supportedFormats {
            let dimension = CMVideoFormatDescriptionGetDimensions(supportedFormat.formatDescription)
            let diff = abs(Int32(targetWidth) - dimension.width) + abs(Int32(targetHeight) - dimension.height)
            if diff < currentDiff {
                selectedFormat = supportedFormat
                currentDiff = diff
            }
        }
        
        if let format = selectedFormat {
            var maxSupportedFramerate: Float64 = 0
            for fpsRange in format.videoSupportedFrameRateRanges {
                maxSupportedFramerate = fmax(maxSupportedFramerate, fpsRange.maxFrameRate)
            }
            let fps = fmin(maxSupportedFramerate, Double(self.cameraSourceFPS))
            
            // Start capture on main queue to avoid session conflicts
            DispatchQueue.main.async {
                frontCapturer.startCapture(with: frontCamera, format: format, fps: Int(fps))
                print("Front camera capture started with format: \(format), fps: \(fps)")
            }
            
            // Wait a bit to ensure capture is started
            Thread.sleep(forTimeInterval: 0.05)
            return true
        }
        
        print("No suitable format found for front camera")
        return false
    }
    
    /// Start back camera capture
    @available(iOS 15.0, *)
    private func startBackCameraCapture() -> Bool {
        print("Starting back camera capture...")
        guard let backCapturer = backVideoCapturer else {
            print("Back capturer is nil")
            return false
        }
        
        // Get back camera device
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Could not get back camera")
            return false
        }
        
        print("Back camera device found: \(backCamera.localizedName)")
        
        // Check if camera is available for use
        do {
            try backCamera.lockForConfiguration()
            backCamera.unlockForConfiguration()
        } catch {
            print("Back camera is not available: \(error)")
            return false
        }
        
        // Start capture with back camera
        let supportedFormats = RTCCameraVideoCapturer.supportedFormats(for: backCamera)
        var selectedFormat: AVCaptureDevice.Format?
        var currentDiff = INT_MAX
        
        for supportedFormat in supportedFormats {
            let dimension = CMVideoFormatDescriptionGetDimensions(supportedFormat.formatDescription)
            let diff = abs(Int32(targetWidth) - dimension.width) + abs(Int32(targetHeight) - dimension.height)
            if diff < currentDiff {
                selectedFormat = supportedFormat
                currentDiff = diff
            }
        }
        
        if let format = selectedFormat {
            var maxSupportedFramerate: Float64 = 0
            for fpsRange in format.videoSupportedFrameRateRanges {
                maxSupportedFramerate = fmax(maxSupportedFramerate, fpsRange.maxFrameRate)
            }
            let fps = fmin(maxSupportedFramerate, Double(self.cameraSourceFPS))
            
            // Start capture on main queue to avoid session conflicts
            DispatchQueue.main.async {
                backCapturer.startCapture(with: backCamera, format: format, fps: Int(fps))
                print("Back camera capture started with format: \(format), fps: \(fps)")
            }
            
            // Wait a bit to ensure capture is started
            Thread.sleep(forTimeInterval: 0.05)
            return true
        }
        
        print("No suitable format found for back camera")
        return false
    }
    
    /// Clean up dual camera resources properly
    @available(iOS 15.0, *)
    private func cleanupDualCameraResources() {
        sessionQueue.async {
            print("Cleaning up dual camera resources...")
            
            // Stop captures on main queue
            DispatchQueue.main.sync {
                self.frontVideoCapturer?.stopCapture()
                self.backVideoCapturer?.stopCapture()
            }
            
            // Remove video tracks from views
            if let frontTrack = self.frontVideoTrack, let localView = self.localVideoView {
                frontTrack.remove(localView)
            }
            
            if let backTrack = self.backVideoTrack, let localView = self.localVideoView {
                backTrack.remove(localView)
            }
            
            // Clear references
            self.frontVideoCapturer = nil
            self.backVideoCapturer = nil
            self.frontVideoTrack = nil
            self.backVideoTrack = nil
            self.frontVideoSender = nil
            self.backVideoSender = nil
            self.frontCameraSession = nil
            self.backCameraSession = nil
            
            print("Dual camera resources cleaned up")
        }
    }
    
    
    public func addLocalMediaStream() -> Bool {
        print("Add local media streams")
        if self.videoEnabled {
            switch cameraMode {
            case .frontOnly, .backOnly:
                // Single camera mode (existing behavior)
                self.localVideoTrack = createVideoTrack()
                
                self.videoSender = self.peerConnection?.add(self.localVideoTrack, streamIds: [LOCAL_MEDIA_STREAM_ID])
                
                if let params = videoSender?.parameters {
                    params.degradationPreference = (self.degradationPreference.rawValue) as NSNumber
                    videoSender?.parameters = params
                } else {
                    print("DegradationPreference cannot be set")
                }
                
            case .dualCamera:
                // Dual camera mode
                if #available(iOS 15.0, *) {
                    print("Starting dual camera mode...")
                    let (frontTrack, backTrack) = createDualCameraVideoTracks()
                    
                    if let frontTrack = frontTrack, let backTrack = backTrack {
                        self.frontVideoTrack = frontTrack
                        self.backVideoTrack = backTrack
                        
                        print("Dual camera tracks created successfully")
                        
                        // Add both tracks to peer connection
                        self.frontVideoSender = self.peerConnection?.add(frontTrack, streamIds: [LOCAL_MEDIA_STREAM_ID])
                        self.backVideoSender = self.peerConnection?.add(backTrack, streamIds: [LOCAL_MEDIA_STREAM_ID])
                        
                        print("Dual camera tracks added to peer connection")
                        
                        // Set degradation preference for both tracks
                        if let frontParams = frontVideoSender?.parameters {
                            frontParams.degradationPreference = (self.degradationPreference.rawValue) as NSNumber
                            frontVideoSender?.parameters = frontParams
                        }
                        
                        if let backParams = backVideoSender?.parameters {
                            backParams.degradationPreference = (self.degradationPreference.rawValue) as NSNumber
                            backVideoSender?.parameters = backParams
                        }
                        
                        print("Dual camera tracks added successfully")
                    } else {
                        print("Failed to create dual camera tracks")
                        return false
                    }
                } else {
                    print("Dual camera requires iOS 15.0 or later")
                    return false
                }
            }
        }
        
        let audioSource = factory.audioSource(with: Config.createTestConstraints())
        self.localAudioTrack = factory.audioTrack(with: audioSource, trackId: AUDIO_TRACK_ID)
        
        self.peerConnection?.add(self.localAudioTrack, streamIds: [LOCAL_MEDIA_STREAM_ID])
        
        // Add video track to local view
        if cameraMode == .dualCamera {
            // For dual camera mode, add front camera to local view
            if #available(iOS 15.0, *) {
                if let localView = self.localVideoView {
                    setMainLocalView(localView)
                } else {
                    print("Local view is nil for dual camera mode")
                }
            }
        } else {
            // For single camera mode
            if let localTrack = self.localVideoTrack, let localView = self.localVideoView {
                localTrack.add(localView)
                print("Single camera track added to local view")
            } else {
                print("Single camera track or local view is nil - localTrack: \(String(describing: self.localVideoTrack)), localView: \(String(describing: self.localVideoView))")
            }
        }
        
        self.delegate?.addLocalStream(streamId: self.streamId)
        return true
    }
    
    public func getLocalVideoTrack() -> RTCVideoTrack {
        return self.localVideoTrack
    }
    
    public func getLocalAudioTrack() -> RTCAudioTrack {
        return self.localAudioTrack
    }
    
    // MARK: - Dual Camera Track Access
    
    @available(iOS 15.0, *)
    public func getFrontVideoTrack() -> RTCVideoTrack? {
        return self.frontVideoTrack
    }
    
    @available(iOS 15.0, *)
    public func getBackVideoTrack() -> RTCVideoTrack? {
        return self.backVideoTrack
    }
    
    @available(iOS 15.0, *)
    public func setLocalViewForCamera(_ camera: CameraMode, view: RTCVideoRenderer) {
        switch camera {
        case .frontOnly:
            if let frontTrack = frontVideoTrack {
                frontTrack.add(view)
                print("Front camera track added to local view")
            }
        case .backOnly:
            if let backTrack = backVideoTrack {
                backTrack.add(view)
                print("Back camera track added to local view")
            }
        case .dualCamera:
            // For dual camera, default to front camera
            if let frontTrack = frontVideoTrack {
                frontTrack.add(view)
                print("Front camera track added to local view (dual camera mode)")
            }
        }
    }
    
    /// Set the main local view for dual camera mode (shows front camera by default)
    @available(iOS 15.0, *)
    public func setMainLocalView(_ view: RTCVideoRenderer) {
        if let frontTrack = frontVideoTrack {
            frontTrack.add(view)
            print("Main local view set to front camera track")
        } else {
            print("Front camera track is nil, cannot set main local view")
        }
    }
    
    /// Restart front camera if it's frozen (public method for external use)
    @available(iOS 15.0, *)
    public func restartFrontCameraIfNeeded() {
        guard cameraMode == .dualCamera else { return }
        
        sessionQueue.async {
            print("Attempting to restart front camera...")
            
            // Stop current front camera
            self.frontVideoCapturer?.stopCapture()
            
            // Wait a moment
            Thread.sleep(forTimeInterval: 0.1)
            
            // Restart front camera
            DispatchQueue.main.async {
                if self.startFrontCameraCapture() {
                    print("Front camera restarted successfully")
                } else {
                    print("Failed to restart front camera")
                }
            }
        }
    }
    
    public func setDegradationPreference(degradationPreference: RTCDegradationPreference) {
        self.degradationPreference = degradationPreference
    }
    
    public func switchCamera() {
        let cameraVideoCapturer = self.videoCapturer as? RTCCameraVideoCapturer
        cameraVideoCapturer?.stopCapture()
        
        if self.cameraPosition == .front {
            self.cameraPosition = .back
        } else {
            self.cameraPosition = .front
        }
        
        startCapture()
    }
    
    public func deliverExternalAudio(sampleBuffer: CMSampleBuffer) {
        self.audioDeviceModule?.deliverRecordedData(sampleBuffer)
    }
    
    public func getVideoCapturer() -> RTCVideoCapturer? {
        return videoCapturer
    }
}

extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        self.delegate?.dataReceivedFromDataChannel(didReceiveData: buffer, streamId: self.streamId)
    }
    
    func dataChannelDidChangeState(_ parametersdataChannel: RTCDataChannel) {
        if parametersdataChannel.readyState == .open {
            print("Data channel state is open")
        } else if parametersdataChannel.readyState == .connecting {
            print("Data channel state is connecting")
        } else if parametersdataChannel.readyState == .closing {
            print("Data channel state is closing")
        } else if parametersdataChannel.readyState == .closed {
            print("Data channel state is closed")
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    
    // signalingStateChanged
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // AntMediaClient.printf("---> StateChanged:\(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        print("didAdd track:\(String(describing: rtpReceiver.track?.kind)) media streams count:\(mediaStreams.count) ")
        
        if let track = rtpReceiver.track {
            self.delegate?.trackAdded(track: track, stream: mediaStreams)
        } else {
            print("New track added but it's nil")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        print("didRemove track:\(String(describing: rtpReceiver.track?.kind))")
        
        if let track = rtpReceiver.track {
            self.delegate?.trackRemoved(track: track)
        } else {
            print("New track removed but it's nil")
        }
    }
    
    // addedStream
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("addedStream. Stream has \(stream.videoTracks.count) video tracks and \(stream.audioTracks.count) audio tracks")
        
        if stream.videoTracks.count == 1 {
            // Single video track (existing behavior)
            print("stream has single video track")
            if remoteVideoView != nil {
                remoteVideoTrack = stream.videoTracks[0]
                
                remoteVideoTrack.add(remoteVideoView!)
                renderRemoteVideo(to: remoteVideoView!)
                
                print("Has delegate??? (signalingStateChanged): \(String(describing: self.delegate))")
            }
        } else if stream.videoTracks.count > 1 {
            // Multiple video tracks (dual camera support)
            print("stream has multiple video tracks: \(stream.videoTracks.count)")
            
            // Handle multiple video tracks
            for (index, track) in stream.videoTracks.enumerated() {
                print("Processing video track \(index) with ID: \(track.trackId)")
                
                // You can identify tracks by their trackId
                if track.trackId == "front_video" {
                    // Handle front camera track
                    print("Front camera track received")
                    if remoteVideoView != nil {
                        remoteVideoTrack = track
                        remoteVideoTrack.add(remoteVideoView!)
                        renderRemoteVideo(to: remoteVideoView!)
                        print("Front camera track added to remote view")
                    }
                } else if track.trackId == "back_video" {
                    // Handle back camera track
                    print("Back camera track received")
                    // For now, we'll use the first track (front) for the main view
                    // In a full implementation, you'd have separate views for each camera
                } else {
                    // Handle other video tracks
                    print("Other video track received: \(track.trackId)")
                    // Use the first available track as fallback
                    if remoteVideoView != nil && remoteVideoTrack == nil {
                        remoteVideoTrack = track
                        remoteVideoTrack.add(remoteVideoView!)
                        renderRemoteVideo(to: remoteVideoView!)
                    }
                }
            }
        }
        
        delegate?.remoteStreamAdded(streamId: self.streamId)
    }
    
    // removedStream
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("RemovedStream")
        delegate?.remoteStreamRemoved(streamId: self.streamId)
        remoteVideoTrack = nil
        remoteAudioTrack = nil
        
        if let remoteVideoView = remoteVideoView {
            removeRenderRemoteVideo(to: remoteVideoView)
        }
    }
    
    // GotICECandidate
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let candidateJson = ["command": "takeCandidate",
                             "type": "candidate",
                             "streamId": self.streamId,
                             "candidate": candidate.sdp,
                             "label": candidate.sdpMLineIndex,
                             "id": candidate.sdpMid] as [String: Any]
        
        self.delegate?.sendMessage(candidateJson)
    }
    
    // iceConnectionChanged
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("---> iceConnectionChanged: \(newState.rawValue) for stream: \(String(describing: self.streamId))")
        self.iceConnectionState = newState
        self.delegate?.connectionStateChanged(newState: newState, streamId: self.streamId)
    }
    
    // iceGatheringChanged
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // AntMediaClient.printf("---> iceGatheringChanged")
    }
    
    // didOpen dataChannel
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("---> dataChannel opened")
        self.dataChannel = dataChannel
        self.dataChannel?.delegate = self
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // AntMediaClient.printf("---> peerConnectionShouldNegotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // AntMediaClient.printf("---> didRemove")
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension WebRTCClient: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let outputData = photo.fileDataRepresentation() else {
            print("Photo Error: \(String(describing: error))")
            return
        }
        loadImage(data: outputData)
    }
}
