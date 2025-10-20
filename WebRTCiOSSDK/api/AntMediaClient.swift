//
//  WebRTCClient.swift
//  AntMediaSDK
//
//  Copyright © 2018 AntMedia. All rights reserved.
//

import Foundation
import AVFoundation
import Starscream
import WebRTC

let TAG: String = "AntMedia_iOS: "

public enum AntMediaClientMode: Int {
    case join = 1
    case play = 2
    case publish = 3
    // deprecated
    case conference = 4
    case unspecified = 5
    
    func getLeaveMessage() -> String {
        switch self {
        case .join:
            return "leave"
        case .publish, .play:
            return "stop"
        case .conference:
            return "leaveRoom"
        case .unspecified:
            return "unspecified"
        }
    }
    
    func getName() -> String {
        switch self {
        case .join:
            return "join"
        case .play:
            return "play"
        case .publish:
            return "publish"
        case .conference:
            return "conference"
        case .unspecified:
            return "unspecified"
        }
    }
    
}

open class AntMediaClient: NSObject, AntMediaClientProtocol {
    
    internal static var isDebug: Bool = false
    internal static var isVerbose: Bool = false
    public weak var delegate: AntMediaClientDelegate?

    private var wsUrl: String!
    // Pending local renderers for dual-camera composite mode
    private var pendingDualFrontRenderer: RTCVideoRenderer?
    private var pendingDualBackRenderer: RTCVideoRenderer?
    private weak var pendingDualFrontContainer: UIView?
    private weak var pendingDualBackContainer: UIView?
    private var publisherStreamId: String?
    /**
     mainTrackId can also be used  the roomId of the conference
     */
    private var mainTrackId: String?
    private var playerStreamId: String?
    private var p2pStreamId: String?
    private var publishToken: String?
    private var playToken: String?
    private var webSocket: Starscream.WebSocket?
    // keep it for backward compatibility
    private var mode: AntMediaClientMode!
    var streamsInTheRoom: [String] = []
    
    var audioLevelGetterTimer: Timer?
    
    var rtcStatsTimer: Timer?
    var rtcStatsStreamIdSet = Set<String>()

    private var webRTCClientMap: [String: WebRTCClient] = [:]

    private var localView: RTCVideoRenderer?
    private var remoteView: RTCVideoRenderer?
    
    // MARK: - Dual Camera Support Properties
    private var cameraMode: CameraMode = .frontOnly
    private var frontRemoteView: RTCVideoRenderer?
    private var backRemoteView: RTCVideoRenderer?
    
    private var videoContentMode: UIView.ContentMode?
    
    private let dispatchQueue = DispatchQueue(label: "audio")
    
    private let rtcAudioSession = RTCAudioSession.sharedInstance()
    
    private var localContainerBounds: CGRect?
    private var remoteContainerBounds: CGRect?
    
    private var cameraPosition: AVCaptureDevice.Position = .front
    
    private var targetWidth: Int = 1_280
    private var targetHeight: Int = 720
    
    private var maxVideoBps: NSNumber = 0
    
    private var videoEnable: Bool = true
    private var audioEnable: Bool = true
            
    private var enableDataChannel: Bool = true
        
    // Screen capture of the app's screen.
    private var useExternalCameraSource: Bool = false
    
    private var isWebSocketConnected: Bool = false
    private var isWebSocketConnecting: Bool = false
    
    private var externalAudioEnabled: Bool = false
    
    // External video capture is getting frames from Broadcast Extension.
    // In order to make the broadcast extension to work both captureScreenEnable and
    // externalVideoCapture should be true
    
    private var externalVideoCapture: Bool = false
    
    private var cameraSourceFPS: Int = 30
    
    /**
    Degradation preference when publishing streams. By default its values is maintainResolution because when resolution changes HLS playback does not play in safari
    */
    private var degradationPreference: RTCDegradationPreference = RTCDegradationPreference.maintainResolution
    
    var pingTimer: Timer?
    
    var disableTrackId: String?
    
    var reconnectIfRequiresScheduled: Bool = false
    
    // Publish gating for dual-camera composite: wait for first local frame
    private var waitFirstFrameBeforePublish: Bool = false
    private var publishHandshakeSent: Bool = false
    private var firstFrameCallbackRegistered: Bool = false
        
    struct HandshakeMessage: Codable {
        var command: String?
        var streamId: String?
        var token: String?
        var video: Bool?
        var audio: Bool?
        var mode: String?
        var mainTrack: String?
        var trackList: [String]
    }
    
    public override init() {
    }
    
    public func setOptions(url: String, streamId: String, token: String = "", mode: AntMediaClientMode = .join, enableDataChannel: Bool = false, useExternalCameraSource: Bool = false) {
        self.wsUrl = url
        self.mode = mode
        
        if mode == AntMediaClientMode.publish {
            self.publisherStreamId = streamId
            self.publishToken = token
            
        } else if mode == AntMediaClientMode.play {
            self.playerStreamId = streamId
            self.playToken = token
            
        } else if mode == AntMediaClientMode.join {
            self.p2pStreamId = streamId
        }
        
        self.enableDataChannel = enableDataChannel
        self.useExternalCameraSource = useExternalCameraSource
    }
    
    // MARK: - Enhanced setOptions with Camera Mode Support
    @available(iOS 15.0, *)
    public func setOptions(
        url: String, 
        streamId: String, 
        token: String = "", 
        mode: AntMediaClientMode = .join, 
        enableDataChannel: Bool = false, 
        useExternalCameraSource: Bool = false,
        cameraMode: CameraMode = .frontOnly
    ) {
        self.wsUrl = url
        self.mode = mode
        self.cameraMode = cameraMode
        
        if mode == AntMediaClientMode.publish {
            self.publisherStreamId = streamId
            self.publishToken = token
            
        } else if mode == AntMediaClientMode.play {
            self.playerStreamId = streamId
            self.playToken = token
            
        } else if mode == AntMediaClientMode.join {
            self.p2pStreamId = streamId
        }
        
        self.enableDataChannel = enableDataChannel
        self.useExternalCameraSource = useExternalCameraSource
        
        print("Options set with camera mode: \(cameraMode)")
    }
    
    public func setWebSocketServerUrl(url: String) {
        self.wsUrl = url
    }
    
    public func setRoomId(roomId: String) {
        self.mainTrackId = roomId
    }
    
    public func setEnableDataChannel(enableDataChannel: Bool) {
        self.enableDataChannel = enableDataChannel
    }
    
    public func setUseExternalCameraSource(useExternalCameraSource: Bool) {
        self.useExternalCameraSource = useExternalCameraSource
    }
    
    public func setMaxVideoBps(videoBitratePerSecond: NSNumber) {
        self.maxVideoBps = videoBitratePerSecond
        self.webRTCClientMap[self.getPublisherStreamId()]?.setMaxVideoBps(maxVideoBps: videoBitratePerSecond)
    }
    
    public func setVideoEnable( enable: Bool) {
        self.videoEnable = enable
    }
    
    public func getStreamId(_ streamId: String = "") -> String {
        // backward compatibility
        if streamId.isEmpty {
            return self.publisherStreamId ?? (self.playerStreamId ?? (self.p2pStreamId ?? ""))
        }
        return streamId
    }
    
    public func getPublisherStreamId() -> String {
        return self.publisherStreamId ?? (self.p2pStreamId ?? "")
    }
    
    func getHandshakeMessage(streamId: String, mode: AntMediaClientMode, token: String = "") -> String {
        
        var trackList: [String] = []
        print("disable track id is \(String(describing: self.disableTrackId))")
        if let trackId = self.disableTrackId {
            print("appending track id to the tracklist \(String(describing: self.disableTrackId))")
            trackList.append("!" + trackId)
        } else {
            print("Disable track id is not set \(String(describing: self.disableTrackId))")
        }
        
        let handShakeMesage = HandshakeMessage(command: mode.getName(), streamId: streamId, token: token, video: self.videoEnable, audio: self.audioEnable, mainTrack: self.mainTrackId, trackList: trackList)
        
        let json = try! JSONEncoder().encode(handShakeMesage)
        return String(data: json, encoding: .utf8)!
    }
    
    public func getLeaveMessage(streamId: String, mode: AntMediaClientMode) -> [String: String] {
        return [COMMAND: mode.getLeaveMessage(), STREAM_ID: streamId]
    }
    
    // Force speaker
    public func speakerOn() {
        dispatchQueue.async {
          
            self.rtcAudioSession.lockForConfiguration()
            
            do {
                try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
                try self.rtcAudioSession.setActive(true)
            } catch {
                print("Couldn't force audio to speaker: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    // Fallback to the default playing device: headphones/bluetooth/ear speaker
    public func speakerOff() {
        dispatchQueue.async {
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.overrideOutputAudioPort(.none)
            } catch {
                debugPrint("Error setting AVAudioSession category: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }

    open func start() {
        initPeerConnection(streamId: self.getStreamId(), mode: self.mode, token: self.publishToken ?? (self.playToken ?? ""))
        
        if !isWebSocketConnected {
            connectWebSocket()
        } else {
            self.websocketConnected()
        }
    }
    
    /**
    Join P2P call
     */
    public func join(streamId: String) {
        self.p2pStreamId = streamId
        resetDefaultWebRTCAudioConfiguation()
        initPeerConnection(streamId: streamId, mode: AntMediaClientMode.join)
        if !isWebSocketConnected {
            connectWebSocket()
        } else {
            sendJoinCommand(streamId)
        }
    }
    
    /**
     Leave from p2p call
     */
    public func leave(streamId: String) {
        if !isWebSocketConnected {
            let leaveMessage = [
                COMMAND: "leave",
                STREAM_ID: streamId] as [String: Any]
            
            webSocket?.write(string: leaveMessage.json)
        }
        self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
    }
    
    public func joinRoom(roomId: String, streamId: String = "") {
        self.mainTrackId = roomId
        self.publisherStreamId = streamId
        self.mode = AntMediaClientMode.conference
        if !isWebSocketConnected {
            connectWebSocket()
        } else {
            sendJoinConferenceCommand()
        }
    }
    
    /**
     Called when the server responds with "joined room notification" as a response to "join room" command
     */
    private func joinedRoom(streamId: String, streams: [String]) {
        self.publisherStreamId = streamId
        self.delegate?.streamIdToPublish(streamId: streamId)
        self.streamsInTheRoom = streams
        
        if !self.streamsInTheRoom.isEmpty {
            self.delegate?.newStreamsJoined(streams: streams)
        }
        
        reconnectIfRequires()
    }
    
    public func leaveFromRoom() {
        if isWebSocketConnected {
            if let roomId = self.mainTrackId {
                let leaveRoomMessage = [
                    COMMAND: "leaveFromRoom",
                    ROOM_ID: roomId,
                    STREAM_ID: self.publisherStreamId ?? "" ] as [String: Any]
                
                webSocket?.write(string: leaveRoomMessage.json)
                print("Sending leaveRoom message \(leaveRoomMessage.json)")
            } else {
                print("Websocket is not connected to send leave from room message")
            }
        }
        
        if let tmpStreamId = self.publisherStreamId {
            self.webRTCClientMap.removeValue(forKey: tmpStreamId)?.disconnect()
        }
        
        if let tmpStreamId = self.playerStreamId {
            self.webRTCClientMap.removeValue(forKey: tmpStreamId)?.disconnect()
        }
    }
    
    // this configuration don't ask for mic permission it's useful for playback
    public func dontAskMicPermissionForPlaying() {
        let webRTCConfiguration = RTCAudioSessionConfiguration()
        webRTCConfiguration.mode = AVAudioSession.Mode.moviePlayback.rawValue
        webRTCConfiguration.category = AVAudioSession.Category.playback.rawValue
        webRTCConfiguration.categoryOptions = AVAudioSession.CategoryOptions.duckOthers
                             
        RTCAudioSessionConfiguration.setWebRTC(webRTCConfiguration)
    }
    
    // this configuration ask mic permission and capture mic record
    open func resetDefaultWebRTCAudioConfiguation() {
        RTCAudioSessionConfiguration.setWebRTC(RTCAudioSessionConfiguration())
    }
    
    public func publish(streamId: String, token: String = "", mainTrackId: String = "") {
    
        self.publisherStreamId = streamId
        // reset default webrtc audio configuation to capture audio and mic
        resetDefaultWebRTCAudioConfiguation()
        // For dual-camera composite, wait for first frame before sending publish handshake
        if #available(iOS 13.0, *), cameraMode == .dualCamera {
            self.waitFirstFrameBeforePublish = true
            self.publishHandshakeSent = false
            self.firstFrameCallbackRegistered = false
            // Wait for previous camera session to fully release hardware
            print("Allowing camera hardware release time before dual camera initialization...")
            
            // Force garbage collection to help release camera resources
            DispatchQueue.main.async {
                // This forces ARC to clean up any lingering references
            }
            
            Thread.sleep(forTimeInterval: 1.5)
        } else {
            self.waitFirstFrameBeforePublish = false
            self.publishHandshakeSent = false
            self.firstFrameCallbackRegistered = false
        }
        initPeerConnection(streamId: streamId, mode: AntMediaClientMode.publish, token: token)
        
        if !mainTrackId.isEmpty {
            self.mainTrackId = mainTrackId
        }
        
        if !token.isEmpty {
            self.publishToken = token
        }
        
        if !isWebSocketConnected {
            connectWebSocket()
        } else {
            sendPublishCommand(streamId)
        }
    }
    
    public func play(streamId: String, token: String = "") {
        
        self.playerStreamId = streamId
        
        if !token.isEmpty {
            self.playToken = token
        }
        
        if let streamId = self.publisherStreamId {
            if self.webRTCClientMap[streamId] == nil {
                // if there is not publisherStreamId, don't ask mic permission for playing
                dontAskMicPermissionForPlaying()
            }
        } else {
            // if there is not publisherStreamId, don't ask mic permission for playing
            dontAskMicPermissionForPlaying()
        }
        
        initPeerConnection(streamId: streamId, mode: AntMediaClientMode.play, token: token)
        
        if !isWebSocketConnected {
            connectWebSocket()
        } else {
            sendPlayCommand(streamId)
        }
    }
    
    /*
     Connect to websocket.
     */
    open func connectWebSocket() {
        dispatchQueue.async {
            print("Connect websocket to \(self.getWsUrl())")
            if !self.isWebSocketConnected && !self.isWebSocketConnecting { // provides backward compatibility
                self.isWebSocketConnecting = true
                self.streamsInTheRoom.removeAll()
                print("Will connect to: \(self.getWsUrl()) for stream: \(self.getStreamId())")
                
                self.webSocket = WebSocket(request: self.getRequest())
                self.webSocket?.delegate = self
                self.webSocket?.connect()
                
            } else {
                if self.isWebSocketConnected {
                    print("WebSocket is already connected to: \(self.getWsUrl())")
                }
                
                if self.isWebSocketConnecting {
                    print("WebSocket is connecting to: \(self.getWsUrl())")
                }
            }
        }
    }
    
    open func setCameraPosition(position: AVCaptureDevice.Position) {
        self.cameraPosition = position
    }
    
    open func setTargetResolution(width: Int, height: Int) {
        self.targetWidth = width
        self.targetHeight = height
    }
    
    open func setTargetFps(fps: Int) {
        self.cameraSourceFPS = fps
    }
    
    /*
     Get a default value to make it compatible with old version
     */
    open func stop(streamId: String = "") {
        rtcAudioSession.remove(self)
        
        let tmpStreamId = getStreamId(streamId)
        
        print("Stop is called for \(tmpStreamId)")
                            
        if tmpStreamId == self.p2pStreamId {
            // provide backward compatibility
            if tmpStreamId == streamId {
                leave(streamId: tmpStreamId)
            }
        } else {
            // removing means that user requests to stop
            unregisterStatsListener(streamId: tmpStreamId)
            // Ensure immediate cleanup without race conditions
            if let client = self.webRTCClientMap.removeValue(forKey: tmpStreamId) {
                client.disconnect()
                print("Client removed from map and disconnected for \(tmpStreamId)")
            }
            
            // Reset publish state flags for clean restart
            self.waitFirstFrameBeforePublish = false
            self.publishHandshakeSent = false
            self.firstFrameCallbackRegistered = false
            
            
            if isWebSocketConnected {
                let command = [
                    COMMAND: "stop",
                    STREAM_ID: tmpStreamId] as [String: String]
                
                webSocket?.write(string: command.json)
            } else {
                print("Websocket is not connected to stop stream:\(tmpStreamId)")
            }
            
            if self.publisherStreamId == tmpStreamId {
                self.publisherStreamId = nil
            } else if self.playerStreamId == tmpStreamId {
                self.playerStreamId = nil
            }
        }
    }
    
    open func initPeerConnection(streamId: String = "", mode: AntMediaClientMode = .unspecified, token: String = "") {
        
        let id = getStreamId(streamId)
        
        // Ensure any existing client is fully cleaned up before creating new one
        if let existingClient = self.webRTCClientMap[id] {
            print("Warning: Client already exists for \(id), cleaning up first")
            existingClient.disconnect()
            self.webRTCClientMap.removeValue(forKey: id)
        }
        
        if self.webRTCClientMap[id] == nil {
            print("Creating new WebRTC client for \(id)")
            
            // Create WebRTC client with appropriate camera mode
            if cameraMode == .dualCamera {
                if #available(iOS 15.0, *) {
                    // Use new dual camera init
                    self.webRTCClientMap[id] = WebRTCClient(
                        remoteVideoView: remoteView,
                        localVideoView: localView,
                        delegate: self,
                        cameraMode: self.cameraMode,
                        targetWidth: self.targetWidth,
                        targetHeight: self.targetHeight,
                        streamId: id
                    )
                } else {
                    print("Dual camera requires iOS 15.0 or later, falling back to single camera")
                    // Fallback to single camera
                    self.webRTCClientMap[id] = WebRTCClient(
                        remoteVideoView: remoteView,
                        localVideoView: localView,
                        delegate: self,
                        cameraPosition: self.cameraPosition,
                        targetWidth: self.targetWidth,
                        targetHeight: self.targetHeight,
                        videoEnabled: self.videoEnable,
                        enableDataChannel: self.enableDataChannel,
                        useExternalCameraSource: self.useExternalCameraSource,
                        externalAudio: self.externalAudioEnabled,
                        externalVideoCapture: self.externalVideoCapture,
                        cameraSourceFPS: self.cameraSourceFPS,
                        streamId: id,
                        degradationPreference: self.degradationPreference
                    )
                }
            } else {
                // Use existing single camera init
                self.webRTCClientMap[id] = WebRTCClient(
                    remoteVideoView: remoteView,
                    localVideoView: localView,
                    delegate: self,
                    cameraPosition: self.cameraPosition,
                    targetWidth: self.targetWidth,
                    targetHeight: self.targetHeight,
                    videoEnabled: self.videoEnable,
                    enableDataChannel: self.enableDataChannel,
                    useExternalCameraSource: self.useExternalCameraSource,
                    externalAudio: self.externalAudioEnabled,
                    externalVideoCapture: self.externalVideoCapture,
                    cameraSourceFPS: self.cameraSourceFPS,
                    streamId: id,
                    degradationPreference: self.degradationPreference
                )
            }
            
            if self.mode != .play {
                // If dual mode and we have pending views, pre-register them before adding stream
                if #available(iOS 13.0, *), self.cameraMode == .dualCamera, let client = self.webRTCClientMap[id] {
                    if let r = self.pendingDualFrontRenderer { client.registerCompositeLocalRenderer(r) }
                    if let r = self.pendingDualBackRenderer { client.registerCompositeLocalRenderer(r) }
                    
                    // Register first frame callback to trigger publish handshake
                    if self.waitFirstFrameBeforePublish && !self.publishHandshakeSent {
                        client.onFirstLocalVideoFrame { [weak self] in
                            guard let self = self else { return }
                            DispatchQueue.main.async {
                                if !self.publishHandshakeSent {
                                    print("First local frame delivered, sending delayed publish handshake")
                                    self.sendPublishCommand(id)
                                }
                            }
                        }
                        
                        // Fallback timeout in case frames never arrive
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                            guard let self = self else { return }
                            if !self.publishHandshakeSent {
                                print("Timeout waiting for first frame - sending publish handshake anyway")
                                self.sendPublishCommand(id)
                            }
                        }
                    }
                }
                
                if !(self.webRTCClientMap[id]?.addLocalMediaStream() ?? false) {
                    print("Failed to add local media stream for id: \(id)")
                    
                    // If dual camera failed, fall back to back camera
                    if #available(iOS 13.0, *), self.cameraMode == .dualCamera {
                        print("Dual camera failed - falling back to back camera mode")
                        self.cameraMode = .backOnly
                        
                        // Remove failed client
                        self.webRTCClientMap.removeValue(forKey: id)?.disconnect()
                        
                        // Create new client with back camera only
                        self.webRTCClientMap[id] = WebRTCClient(
                            remoteVideoView: remoteView,
                            localVideoView: localView,
                            delegate: self,
                            cameraPosition: .back,
                            targetWidth: self.targetWidth,
                            targetHeight: self.targetHeight,
                            videoEnabled: self.videoEnable,
                            enableDataChannel: self.enableDataChannel,
                            useExternalCameraSource: self.useExternalCameraSource,
                            externalAudio: self.externalAudioEnabled,
                            externalVideoCapture: self.externalVideoCapture,
                            cameraSourceFPS: self.cameraSourceFPS,
                            streamId: id,
                            degradationPreference: self.degradationPreference
                        )
                        
                        if !(self.webRTCClientMap[id]?.addLocalMediaStream() ?? false) {
                            print("Failed to add local media stream even with back camera fallback")
                            self.webRTCClientMap.removeValue(forKey: id)
                            return
                        }
                        
                        // Reset dual camera gating since we're now using single camera
                        self.waitFirstFrameBeforePublish = false
                        print("Fallback to back camera successful - proceeding with single camera")
                    } else {
                        // Handle error, e.g., notify delegate, remove client
                        self.webRTCClientMap.removeValue(forKey: id)
                        return
                    }
                }
            }
                        
            self.webRTCClientMap[id]?.setToken(token)
            
            rtcAudioSession.add(self)
        } else {
            // it may initialized without correct token parameter because of backward compatibility
            self.webRTCClientMap[id]?.setToken(token)
            print("WebRTCClient already initialized for id:\(id) and mode:\(mode.getName())")
        }
    }
    
    /*
     Just switches the camera. It works on the fly as well
     */
    open func switchCamera() {
        self.webRTCClientMap[(self.publisherStreamId ?? (self.p2pStreamId)) ?? ""]?.switchCamera()
    }
    
    /**
     Instant zoom
     1.0 means no zoom, 2.0 means 2x zoom, and so on.
     The method ensures the zoom does not exceed the camera’s limits.
     */
    // Source: https://stackoverflow.com/a/42928452/14445061
    @available(iOS 15.0, *)
    public func didZoomingBegan(_ pinch: UIPinchGestureRecognizer) {
        guard let streamId = publisherStreamId,
              let stream = webRTCClientMap[streamId],
              let device = self.cameraMode == .dualCamera ? stream.dualComposer?.backCameraDevice : stream._currentCaptureDevice else { return }
        
        // Return zoom value between the minimum and maximum zoom values
        func minMaxZoom(_ factor: CGFloat) -> CGFloat {
            return min(min(max(factor, stream.minimumZoom), stream.maximumZoom), device.activeFormat.videoMaxZoomFactor)
        }
        
        func update(scale factor: CGFloat) {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = factor
            } catch {
                print("\(error.localizedDescription)")
            }
        }
        
        let newScaleFactor = minMaxZoom(pinch.scale * stream.lastZoomFactor)
        switch pinch.state {
        case .began: fallthrough
        case .changed: update(scale: newScaleFactor)
        case .ended:
            stream.lastZoomFactor = minMaxZoom(newScaleFactor)
            update(scale: stream.lastZoomFactor)
        default: break
        }
    }
    
    
    open func setZoomLevel(zoomFactor: CGFloat) {
       guard let streamId = publisherStreamId, let camera = webRTCClientMap[streamId]?.captureDevice else { return }

       do {
           try camera.lockForConfiguration()
           camera.videoZoomFactor = max(1.0, min(zoomFactor, camera.activeFormat.videoMaxZoomFactor)) // Keep within limits
           camera.unlockForConfiguration()
       } catch {
           print("Failed to set zoom level: \(error)")
       }
    }

    /**
     Smooth zoom
     The rate controls how fast the zoom happens.
     Lower values (e.g., 1.0) mean slow zoom; higher values (e.g., 5.0) mean faster zoom.
     */
    open func smoothZoom(to zoomFactor: CGFloat, rate: Float) {
       guard let streamId = publisherStreamId, let camera = webRTCClientMap[streamId]?.captureDevice else { return }

       do {
           try camera.lockForConfiguration()
           camera.ramp(toVideoZoomFactor: max(1.0, min(zoomFactor, camera.activeFormat.videoMaxZoomFactor)), withRate: rate)
           camera.unlockForConfiguration()
       } catch {
           print("Failed to ramp zoom: \(error)")
       }
    }
    /**
     If a zoom ramp is in progress, you can cancel it immediately:
     */
    open func stopZoomRamp() {
       guard let streamId = publisherStreamId, let camera = webRTCClientMap[streamId]?.captureDevice else { return }

       do {
           try camera.lockForConfiguration()
           camera.cancelVideoZoomRamp()
           camera.unlockForConfiguration()
       } catch {
           print("Failed to cancel zoom ramp: \(error)")
       }
    }

    /*
     Send data through WebRTC Data channel.
     */
    open func sendData(data: Data, binary: Bool = false, streamId: String = "") {
        self.webRTCClientMap[getStreamId(streamId)]?.sendData(data: data, binary: binary)
    }
    
    open func isDataChannelActive(streamId: String = "") -> Bool {
       
        return self.webRTCClientMap[getStreamId(streamId)]?.isDataChannelActive() ?? false
    }
        
    open func setLocalView(container: UIView, mode: UIView.ContentMode = .scaleAspectFit) {
        // Remove previous renderer view if exists to prevent stacking
        if let old = self.localView as? UIView { old.removeFromSuperview() }
        #if arch(arm64)
        let localRenderer = RTCMTLVideoView(frame: container.frame)
        localRenderer.videoContentMode = mode
        #else
        let localRenderer = RTCEAGLVideoView(frame: container.frame)
        localRenderer.delegate = self
        #endif
 
        localRenderer.frame = container.bounds
        self.localView = localRenderer
        self.localContainerBounds = container.bounds
        
        AntMediaClient.embedView(localRenderer, into: container)
    }
    
    open func setRemoteView(remoteContainer: UIView, mode: UIView.ContentMode = .scaleAspectFit) {
        // Remove previous renderer view if exists to prevent stacking
        if let old = self.remoteView as? UIView { old.removeFromSuperview() }
        #if arch(arm64)
        let remoteRenderer = RTCMTLVideoView(frame: remoteContainer.frame)
        remoteRenderer.videoContentMode = mode
        #else
        let remoteRenderer = RTCEAGLVideoView(frame: remoteContainer.frame)
        remoteRenderer.delegate = self
        #endif
        
        remoteRenderer.frame = remoteContainer.frame
        
        self.remoteView = remoteRenderer
        self.remoteContainerBounds = remoteContainer.bounds
        AntMediaClient.embedView(remoteRenderer, into: remoteContainer)
    }
    
    // MARK: - Dual Camera Support
    
    /// Set dual camera mode for WebRTC client
    @available(iOS 15.0, *)
    open func setCameraMode(_ mode: CameraMode) {
        self.cameraMode = mode
        
        // Update all existing WebRTC clients
        for (_, client) in webRTCClientMap {
            client.setCameraMode(mode)
        }
        
        
        
        print("Camera mode set to: \(mode)")
    }
    
    /// Get current camera mode
    @available(iOS 15.0, *)
    open func getCameraMode() -> CameraMode {
        return self.cameraMode
    }
    
    /// Check if device supports multi-camera
    @available(iOS 15.0, *)
    open func isMultiCamSupported() -> Bool {
        return WebRTCClient.isMultiCamSupported()
    }

    /// Set dual remote views for front and back camera
    @available(iOS 15.0, *)
    open func setDualRemoteViews(
        frontContainer: UIView,
        backContainer: UIView,
        mode: UIView.ContentMode = .scaleAspectFit
    ) {
        // Create front camera view
        #if arch(arm64)
        let frontRenderer = RTCMTLVideoView(frame: frontContainer.frame)
        frontRenderer.videoContentMode = mode
        #else
        let frontRenderer = RTCEAGLVideoView(frame: frontContainer.frame)
        frontRenderer.delegate = self
        #endif
        
        frontRenderer.frame = frontContainer.bounds
        self.frontRemoteView = frontRenderer
        AntMediaClient.embedView(frontRenderer, into: frontContainer)
        
        // Create back camera view
        #if arch(arm64)
        let backRenderer = RTCMTLVideoView(frame: backContainer.frame)
        backRenderer.videoContentMode = mode
        #else
        let backRenderer = RTCEAGLVideoView(frame: backContainer.frame)
        backRenderer.delegate = self
        #endif
        
        backRenderer.frame = backContainer.bounds
        self.backRemoteView = backRenderer
        AntMediaClient.embedView(backRenderer, into: backContainer)
        
        print("Dual remote views set successfully")
    }
    
    /// Set local view for dual camera mode
    @available(iOS 15.0, *)
    open func setDualLocalViews(
        frontContainer: UIView,
        backContainer: UIView,
        mode: UIView.ContentMode = .scaleAspectFit
    ) {
        
        // Create front camera local view
        #if arch(arm64)
        let frontRenderer = RTCMTLVideoView(frame: frontContainer.frame)
        frontRenderer.videoContentMode = mode
        #else
        let frontRenderer = RTCEAGLVideoView(frame: frontContainer.frame)
        frontRenderer.delegate = self
        #endif
        
        frontRenderer.frame = frontContainer.bounds
        AntMediaClient.embedView(frontRenderer, into: frontContainer)
        
        // Create back camera local view
        #if arch(arm64)
        let backRenderer = RTCMTLVideoView(frame: backContainer.frame)
        backRenderer.videoContentMode = mode
        #else
        let backRenderer = RTCEAGLVideoView(frame: backContainer.frame)
        backRenderer.delegate = self
        #endif
        
        backRenderer.frame = backContainer.bounds
        AntMediaClient.embedView(backRenderer, into: backContainer)
                
        // Connect tracks to views
        // Always keep references first; client may not exist yet if called before publish()
        self.pendingDualFrontRenderer = frontRenderer
        self.pendingDualBackRenderer = backRenderer
        
        let streamId = getPublisherStreamId()
        if let client = webRTCClientMap[streamId] {
            if #available(iOS 13.0, *) {
                if client.getCameraMode() == .dualCamera {
                    client.registerCompositeLocalRenderer(frontRenderer)
                    client.registerCompositeLocalRenderer(backRenderer)
                    print("Registered composite renderers on existing client")
                } else {
                    client.setLocalViewForCamera(.frontOnly, view: frontRenderer)
                    client.setLocalViewForCamera(.backOnly, view: backRenderer)
                }
            } else {
                client.setDualCameraViews(frontView: frontRenderer, backView: backRenderer)
            }
        } else {
            print("No client yet; stored dual local renderers for later binding")
        }
        
        print("Dual local views set successfully")
    }
    
    open func disableTrack(trackId: String) {
        self.disableTrackId = trackId
    }
    
    public static func embedView(_ view: UIView, into containerView: UIView) {
        containerView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "H:|[view]|",
                                                                    options: [],
                                                                    metrics: nil,
                                                                    views: ["view": view]))
        
        containerView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[view]|",
                                                                    options: [],
                                                                    metrics: nil,
                                                                    views: ["view": view]))
        containerView.layoutIfNeeded()
    }
    
    open func isConnected() -> Bool {
        return isWebSocketConnected
    }
    
    open func setDebug(_ value: Bool) {
        AntMediaClient.isDebug = value
    }
    
    public static func setDebug(_ value: Bool) {
        AntMediaClient.isDebug = value
    }
    
    /*
     Toggle publisher audo
     */
    open func toggleAudio() {
        self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.toggleAudioEnabled()
        
        if let audioEnabled = self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.isAudioEnabled() {
            self.sendAudioTrackStatusNotification(enabled: audioEnabled)
        }
    }
    
    func sendAudioTrackStatusNotification(enabled: Bool) {
        var eventType = EVENT_TYPE_MIC_MUTED
        
        if enabled {
            eventType = EVENT_TYPE_MIC_UNMUTED
        }
        
        if let streamId = self.publisherStreamId {
            self.sendNotification(eventType: eventType, streamId: streamId)
        }
    }
    /*
     Set publisher audio track
     */
    open func setAudioTrack(enableTrack: Bool) {
        self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.setAudioEnabled(enabled: enableTrack)
        self.sendAudioTrackStatusNotification(enabled: enableTrack)
    }
    
    open func getLocalAudioTrack() -> RTCAudioTrack? {
        self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.getLocalAudioTrack()
    }
    
    open func getLocalVideoTrack() -> RTCVideoTrack? {
        self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.getLocalVideoTrack()
    }
    
    func sendNotification(eventType: String, streamId: String = "") {
        
        let notification = [
            EVENT_TYPE: eventType,
            STREAM_ID: self.getStreamId()].json
        
        if let data = notification.data(using: .utf8) {
            self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.sendData(data: data)
        }
    }
    
    open func setMicMute( mute: Bool, completionHandler: @escaping (Bool, Error?) -> Void) {
        dispatchQueue.async {
            self.rtcAudioSession.lockForConfiguration()
            
            do {
                
                //try self.rtcAudioSession.setCategory(category)
                // playAndRecord category defaults receiver to set to speaker
                //try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
                //try self.rtcAudioSession.setActive(true)
                self.webRTCClientMap[self.getPublisherStreamId()]?.setAudioEnabled(enabled: !mute)
                self.sendNotification(eventType: mute ? EVENT_TYPE_MIC_MUTED : EVENT_TYPE_MIC_UNMUTED)
                completionHandler(mute, nil)
                
            } catch {
                print("Couldn't set to mic status: \(error)")
                completionHandler(mute, error)
            }
            
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    @available(iOS 15.0, *)
    open func focus(
        with focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
        at devicePoint: CGPoint,
        monitorSubjectAreaChange: Bool
    ) {
        dispatchQueue.async {
            guard let streamId = self.publisherStreamId,
                  let stream = self.webRTCClientMap[streamId],
                  let device = self.cameraMode == .dualCamera ? (stream._dualComposer as? DualCameraComposer)?.backCameraDevice : stream._currentCaptureDevice else { return }
            do {
                try device.lockForConfiguration()
                if  device.isFocusPointOfInterestSupported &&
                        device.isFocusModeSupported(focusMode)
                {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = true
                    }
                }
                
                if  device.isExposurePointOfInterestSupported &&
                        device.isExposureModeSupported(exposureMode)
                {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }
                
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = true
                }
                
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                print("couldn't lock device for configuration: \(error)")
            }
        }
    }
    
    open func toggleVideo() {
        self.webRTCClientMap[getPublisherStreamId()]?.toggleVideoEnabled()
        
        if let videoEnabled = self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.isVideoEnabled() {
            self.sendVideoTrackStatusNotification(enabled: videoEnabled)
        }
    }
    
    func sendVideoTrackStatusNotification(enabled: Bool) {
        var eventType = EVENT_TYPE_CAM_TURNED_OFF
        if enabled {
            eventType = EVENT_TYPE_CAM_TURNED_ON
        }
        
        if let streamId = self.publisherStreamId {
            self.sendNotification(eventType: eventType, streamId: streamId)
        }
    }
    
    open func setVideoTrack(enableTrack: Bool) {
        self.webRTCClientMap[getPublisherStreamId()]?.setVideoEnabled(enabled: enableTrack)
        self.sendVideoTrackStatusNotification(enabled: enableTrack)
    }
    
    open func getCurrentMode() -> AntMediaClientMode {
        return self.mode
    }
    
    open func getWsUrl() -> String {
        return wsUrl
    }
    
    fileprivate func sendPublishCommand(_ streamId: String) {
        if !isWebSocketConnected {
            print("Websocket is not connected to send Publish message for stream\(streamId)")
            return
        }

        // In dual-camera composite, wait for the first local frame before sending handshake
        if #available(iOS 13.0, *), cameraMode == .dualCamera, let client = self.webRTCClientMap[streamId] {
            if waitFirstFrameBeforePublish && !publishHandshakeSent && !firstFrameCallbackRegistered {
                print("Delaying publish handshake until first local frame is delivered")
                // Only register the callback if it hasn't been registered yet
                if client.hasDeliveredFirstFrame {
                    // First frame already delivered, send immediately
                    let jsonString = self.getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.publish, token: self.publishToken ?? "")
                    self.webSocket?.write(string: jsonString)
                    self.publishHandshakeSent = true
                    print("Send Publish onConnection message (first frame already delivered): \(jsonString)")
                    self.dispatchQueue.asyncAfter(deadline: .now() + 5.0) { self.reconnectIfRequires() }
                } else {
                    // Register callback for when first frame arrives
                    self.firstFrameCallbackRegistered = true
                    client.onFirstLocalVideoFrame { [weak self] in
                        guard let self = self else { return }
                        if !self.publishHandshakeSent {
                            let jsonString = self.getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.publish, token: self.publishToken ?? "")
                            self.webSocket?.write(string: jsonString)
                            self.publishHandshakeSent = true
                            print("Send Publish onConnection message (after first frame): \(jsonString)")
                            self.dispatchQueue.asyncAfter(deadline: .now() + 5.0) { self.reconnectIfRequires() }
                        }
                    }
                }
                return
            }
        }

        let jsonString = getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.publish, token: self.publishToken ?? "")
        webSocket?.write(string: jsonString)
        publishHandshakeSent = true
        print("Send Publish onConnection message: \(jsonString)")
        dispatchQueue.asyncAfter(deadline: .now() + 5.0) { self.reconnectIfRequires() }
    }
    
    func sendJoinConferenceCommand() {
        if isWebSocketConnected {
            if let roomId = self.mainTrackId {
                let joinRoomMessage = [
                    COMMAND: "joinRoom",
                    ROOM_ID: roomId,
                    MODE: "multitrack",
                    STREAM_ID: self.publisherStreamId ?? "" ] as [String: String]
                webSocket?.write(string: joinRoomMessage.json)
            } else {
                print("mainTrackId is not specified to join the room ")
            }
        } else {
            print("Websocket is not connected to send joinConferece message for room \(String(describing: self.mainTrackId))")
        }
    }
    
    fileprivate func sendPlayCommand(_ streamId: String) {
        if isWebSocketConnected {
            let jsonString = getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.play, token: self.playToken ?? "")
            webSocket?.write(string: jsonString)
            print("Play onConnection message: \(jsonString)")
            
            // Add 3 seconds delay here and reconnectIfRequires has also 3 seconds delay
            dispatchQueue.asyncAfter(deadline: .now() + 5.0) {
                self.reconnectIfRequires()
            }
        } else {
            print("Websocket is not connected to send play message for stream: \(streamId)")
        }
    }
    
    fileprivate func sendJoinCommand(_ streamId: String) {
        let jsonString = getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.join)
        webSocket?.write(string: jsonString)
        print("P2P onConnection message: \(jsonString)")
    }
    
    private func websocketConnected() {
        if isWebSocketConnected {
            if mode == AntMediaClientMode.conference {
                sendJoinConferenceCommand()
            }
            // multiple modes can be active at a time so they are "if" statement
            if let streamId = self.publisherStreamId {
                sendPublishCommand(streamId)
            }
            if let streamId = self.playerStreamId {
                sendPlayCommand(streamId)
            }
            if let streamId = self.p2pStreamId {
                sendJoinCommand(streamId)
            }
        }
        
        // setup for audio interruption notification
        self.setupAudioNotifications()
    }
    
    private func websocketDisconnected(message: String, code: UInt16) {
        self.delegate?.clientDidDisconnect(message)
        self.reconnectIfRequires()
    }
    
    /**
     Re-connection Scenario based on Ice Connection State because No matter websocket is disconnected or webrtc is disconnected
     , ice Connection states changes to disconnected and below `reconnectIfRequires` method is called when ice connection is disconnected.
     
     `reconnectIfRequires` checks if connection is in the map because if the connection is stopped by the user, it's removed from the map, then there is nothing to do.
     If it's not removed from the map and its state is closed, disconnected or failed it means that is a reconnect scenario is required.
     
    This method is also called after joining a room to check if it requires to reconnect
     
     */
    private func reconnectIfRequires() {
        if self.reconnectIfRequiresScheduled {
            print("ReconnectIfRequires is already scheduled and it will work soon")
            return
        }
        
        self.reconnectIfRequiresScheduled = true
        
        dispatchQueue.asyncAfter(deadline: .now() + 3.0) {
            self.reconnectIfRequiresScheduled = false
            
            if let streamId = self.publisherStreamId {
                
                // if there is a webRTCClient in the map, it means it's disconnected due to network issue
                if self.webRTCClientMap[streamId] != nil {
                    let iceState = self.webRTCClientMap[streamId]?.getIceConnectionState()
                    
                    // check the ice state if this method is triggered consequently
                    if  iceState == RTCIceConnectionState.closed ||
                        iceState == RTCIceConnectionState.disconnected ||
                        iceState == RTCIceConnectionState.failed ||
                        iceState == RTCIceConnectionState.new {
                        
                        // clean the connection
                        self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                        print("Reconnecting to publish the stream:\(streamId)")
                        self.publish(streamId: streamId)
                    } else {
                        print("Not trying to reconnect to publish the stream:\(streamId) because ice connection state is not disconnected")
                    }
                }
            }
            
            if let streamId = self.playerStreamId {
                // if there is a webRTCClient in the map, it means it's disconnected due to network issue
                
                let iceState = self.webRTCClientMap[streamId]?.getIceConnectionState()
                
                // check the ice state if this method is triggered consequently
                if   iceState == RTCIceConnectionState.closed ||
                     iceState == RTCIceConnectionState.disconnected ||
                     iceState == RTCIceConnectionState.failed ||
                     iceState == RTCIceConnectionState.new {
                    
                    // clean the connection
                    self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                    print("Reconnecting to play the stream:\(streamId)")
                    self.play(streamId: streamId)
                } else {
                    print("Not trying to reconnect to play the stream:\(streamId) because ice connection state is not disconnected")
                }
            }
            
            if let streamId = self.p2pStreamId {
                
                // if there is a webRTCClient in the map, it means it's disconnected due to network issue
                if self.webRTCClientMap[streamId] != nil {
                    let iceState = self.webRTCClientMap[streamId]?.getIceConnectionState()
                    
                    // check the ice state if this method is triggered consequently
                    if  iceState == RTCIceConnectionState.closed ||
                        iceState == RTCIceConnectionState.disconnected ||
                        iceState == RTCIceConnectionState.failed {
                        
                        // clean the connection
                        self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                        print("Reconnecting to join the stream:\(streamId) because ice connection state is not disconnected")
                        self.join(streamId: streamId)
                    }
                }
            }
        }
    }
    
    private func onJoined() { }
    
    private func onTakeConfiguration(message: [String: Any], streamId: String) {
        var rtcSessionDesc: RTCSessionDescription
        let type = message["type"] as! String
        let sdp = message["sdp"] as! String
        
        if type == "offer" {
            rtcSessionDesc = RTCSessionDescription(type: RTCSdpType.offer, sdp: sdp)
            self.webRTCClientMap[streamId]?.setRemoteDescription(rtcSessionDesc, completionHandler: { error in
                if error == nil {
                    self.webRTCClientMap[streamId]?.sendAnswer()
                } else {
                    print("Error (setRemoteDescription): " + error!.localizedDescription + " debug description: " + error.debugDescription)
                }
            })
        } else if type == "answer" {
            rtcSessionDesc = RTCSessionDescription(type: RTCSdpType.answer, sdp: sdp)
            self.webRTCClientMap[streamId]?.setRemoteDescription(rtcSessionDesc, completionHandler: { _ in
                
            })
        }
    }
    
    private func onTakeCandidate(message: [String: Any], streamId: String) {
        let mid = message["id"] as! String
        let index = message["label"] as! Int
        let sdp = message["candidate"] as! String
        let candidate: RTCIceCandidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: mid)
        self.webRTCClientMap[streamId]?.addCandidate(candidate)
    }
    
    private func onMessage(_ msg: String) {
        if let message = msg.toJSON() {
            guard let command = message[COMMAND] as? String else {
                return
            }
            self.onCommand(command, message: message)
        } else {
            print("WebSocket message JSON parsing error: " + msg)
        }
    }
    
    private func onCommand(_ command: String, message: [String: Any]) {
        switch command {
        case "start":
            // if this is called, it's publisher or initiator in p2p
            let streamId = message[STREAM_ID] as! String
            self.webRTCClientMap[streamId]?.createOffer()
        case "stop":
            let streamId = message[STREAM_ID] as! String
            dispatchQueue.async {
                self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
            }
        case "takeConfiguration":
            let streamId = message[STREAM_ID] as! String
            self.onTakeConfiguration(message: message, streamId: streamId)
        case "takeCandidate":
            let streamId = message[STREAM_ID] as! String
            self.onTakeCandidate(message: message, streamId: streamId)
        case STREAM_INFORMATION_COMMAND:
            print("stream information command")
            var streamInformations: [StreamInformation] = []
            
            if let streamInformationArray = message["streamInfo"] as? [Any] {
                for result in streamInformationArray {
                    if let resultObject = result as? [String: Any] {
                        streamInformations.append(StreamInformation(json: resultObject))
                    }
                }
            }
            self.delegate?.streamInformation(streamInfo: streamInformations)
        case "notification":
            guard let definition = message["definition"] as? String else {
                return
            }
            
            if definition == "joined" {
                print("Joined: Let's go")
                self.onJoined()
                
            } else if definition == "play_started" {
                let streamId = message[STREAM_ID] as! String
                print("Play started: Let's go")
                self.delegate?.playStarted(streamId: streamId)
                
            } else if definition == "play_finished" {
                print("Playing has finished")
                self.streamsInTheRoom.removeAll()
                let streamId = message[STREAM_ID] as! String
                self.delegate?.playFinished(streamId: streamId)
                self.unregisterStatsListener(streamId: streamId)
                
            } else if definition == "publish_started" {
                let streamId = message[STREAM_ID] as! String
                print("Publish started: Let's go")
                self.webRTCClientMap[streamId]?.setMaxVideoBps(maxVideoBps: self.maxVideoBps)
                self.delegate?.publishStarted(streamId: message[STREAM_ID] as! String)
                self.webRTCClientMap[streamId]?.sendTimestamp()
                
            } else if definition == "publish_finished" {
                let streamId = message[STREAM_ID] as! String
                print("Publish finished: Let's close")
                self.delegate?.publishFinished(streamId: streamId)
                self.unregisterStatsListener(streamId: streamId)
                self.webRTCClientMap[streamId]?.stopSendTimestamp()
                
            } else if definition == JOINED_ROOM_DEFINITION {
                let streamId = message[STREAM_ID] as! String
                let streams = message[STREAMS] as! [String]
                self.joinedRoom(streamId: streamId, streams: streams)
                
            } else if definition == BROADCAST_OBJECT_NOTIFICATION { // broadcastObject
                let broadcastString = message["broadcast"] as! String
                let broadcastObject = broadcastString.toJSON()
                self.delegate?.onLoadBroadcastObject(
                    streamId: message[STREAM_ID] as! String,
                    message: broadcastObject ?? [:]
                )
                
            } else if definition == RESOLUTION_CHANGE_INFO_COMMAND {
                let streamId = message[STREAM_ID] as? String ?? ""
                self.delegate?.eventHappened(streamId: streamId, eventType: definition, payload: message)
            }
        case ROOM_INFORMATION_COMMAND:
            if let updatedStreamsInTheRoom = message[STREAMS] as? [String] {
                // check that there is a new stream exists
                var newStreams: [String] = []
                var leftStreams: [String] = []
                
                for stream in updatedStreamsInTheRoom {
                    // AntMedia.printf("stream in updatestreamInTheRoom \(stream)")
                    if !self.streamsInTheRoom.contains(stream) {
                        newStreams.append(stream)
                    }
                }
                
                // check that any stream is left
                for stream in self.streamsInTheRoom {
                    if !updatedStreamsInTheRoom.contains(stream) {
                        leftStreams.append(stream)
                    }
                }
                self.streamsInTheRoom = updatedStreamsInTheRoom
                
                if !newStreams.isEmpty {
                    self.delegate?.newStreamsJoined(streams: newStreams)
                }
                
                if !leftStreams.isEmpty {
                    self.delegate?.streamsLeft(streams: leftStreams)
                }
            }
        case "pong": break
        case "error":
            guard let definition = message["definition"] as? String else {
                self.delegate?.clientHasError("An error occured, please try again")
                return
            }
            
            self.delegate?.clientHasError(AntMediaError.localized(definition))
        default:
            print("Unknown message received -> \(message)")
        }
    }
    
    private func getRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: self.getWsUrl())!)
        request.timeoutInterval = 5
        return request
    }
    
    public static func printf(_ msg: String) {
        if AntMediaClient.isDebug {
            debugPrint("--> AntMediaSDK: " + msg)
        }
    }
    
    public static func verbose(_ msg: String) {
        if AntMediaClient.isVerbose {
            debugPrint("--> AntMediaSDK[verbose]: " + msg)
        }
    }
    
    public func getStreamInfo() {
        if self.isWebSocketConnected {
            self.webSocket?.write(string: [COMMAND: GET_STREAM_INFO_COMMAND, STREAM_ID: self.playerStreamId].json)
        } else {
            print("Websocket is not connected")
        }
    }
    
    public func forStreamQuality(resolutionHeight: Int) {
        if self.isWebSocketConnected {
            self.webSocket?.write(string: [COMMAND: FORCE_STREAM_QUALITY_INFO, STREAM_ID: (self.playerStreamId!), STREAM_HEIGHT_FIELD: resolutionHeight].json)
        } else {
            print("Websocket is not connected")
        }
    }
    
    public func forceStreamQuality(resolutionHeight: Int, streamId: String) {
        if self.isWebSocketConnected {
            self.webSocket?.write(string: [COMMAND: FORCE_STREAM_QUALITY_INFO, STREAM_ID: (self.playerStreamId!), TRACK_ID: streamId, STREAM_HEIGHT_FIELD: resolutionHeight].json)
        } else {
            print("Websocket is not connected")
        }
    }
    
    public func registerStatsListener(for streamId: String, timeInterval: Double = 5) {
        self.rtcStatsTimer?.invalidate()
        
        self.rtcStatsStreamIdSet.insert(streamId)
        self.rtcStatsTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { [weak self] _ in
            
            guard let self = self else { return }

            var itemsToRemove: Set<String> = []

            for streamIdInSet in rtcStatsStreamIdSet {
                
                if let webRTCClient = self.webRTCClientMap[streamIdInSet] {
                    webRTCClient.getStats(handler: { report in
                        self.delegate?.onStats(streamId: streamIdInSet, statistics: report)
                    })
                } else {
                    itemsToRemove.insert(streamIdInSet)
                }
            }
            
            for itemToRemove in itemsToRemove {
                self.unregisterStatsListener(streamId: itemToRemove)
            }
        }
    }
    
    public func unregisterStatsListener(streamId: String) {
        self.rtcStatsStreamIdSet.remove(streamId)
        
        if self.rtcStatsStreamIdSet.isEmpty {
            self.rtcStatsTimer?.invalidate()
            self.rtcStatsTimer = nil
        }
    }
    
    public func getStats(completionHandler: @escaping (RTCStatisticsReport) -> Void, streamId: String = "") {
        self.webRTCClientMap[self.getStreamId(streamId)]?.getStats(handler: completionHandler)
    }
    
    public func getStatistics(for streamId: String = "", completion: @escaping (ClientStatistics) -> Void) {
        getStats(completionHandler: { report in
            completion(.init(items: report.statistics.extractRTCStatItems()))
        }, streamId: streamId)
    }
    
    public func deliverExternalAudio(sampleBuffer: CMSampleBuffer) {
        self.webRTCClientMap[getPublisherStreamId()]?.deliverExternalAudio(sampleBuffer: sampleBuffer)
    }
    
    public func setExternalAudio(externalAudioEnabled: Bool) {
        self.externalAudioEnabled = externalAudioEnabled
    }
    
    public func setExternalVideoCapture(externalVideoCapture: Bool) {
        self.externalVideoCapture = externalVideoCapture
    }
    
    public func deliverExternalVideo(sampleBuffer: CMSampleBuffer, rotation: Int = -1) {
        (self.webRTCClientMap[self.getPublisherStreamId()]?.getVideoCapturer() as? RTCCustomFrameCapturer)?.capture(sampleBuffer, externalRotation: rotation)
    }
    
    public func deliverExternalPixelBuffer(pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation, timestampNs: Int64) {
        (self.webRTCClientMap[self.getPublisherStreamId()]?.getVideoCapturer() as? RTCCustomFrameCapturer)?.capture(pixelBuffer, rotation: rotation, timeStampNs: timestampNs)
    }
    
    public func enableVideoTrack(trackId: String, enabled: Bool) {
        if isWebSocketConnected {
            
            let jsonString = [
                COMMAND: ENABLE_VIDEO_TRACK_COMMAND,
                TRACK_ID: trackId,
                STREAM_ID: self.playerStreamId!,
                ENABLED: enabled
            ].json
            
            webSocket?.write(string: jsonString)
        }
    }
    
    public func enableAudioTrack(trackId: String, enabled: Bool) {
        
        if isWebSocketConnected {
            let jsonString = [
                COMMAND: ENABLE_AUDIO_TRACK_COMMAND,
                TRACK_ID: trackId,
                STREAM_ID: self.playerStreamId!,
                ENABLED: enabled].json
            
            webSocket?.write(string: jsonString)
        }
    }
    
    public func enableTrack(trackId: String, enabled: Bool) {
        if isWebSocketConnected {
            let jsonString = [
                COMMAND: ENABLE_TRACK_COMMAND,
                TRACK_ID: trackId,
                STREAM_ID: self.playerStreamId!,
                ENABLED: enabled].json
            
            webSocket?.write(string: jsonString)
        } else {
            print("Websocket is not connected to enableTRack for track: \(trackId) in stream: \(self.playerStreamId)")
        }
    }
    
    public func setDegradationPreference(_ degradationPreference: RTCDegradationPreference) {
       self.degradationPreference = degradationPreference
       let rtc = self.webRTCClientMap[self.getPublisherStreamId()]

       guard let params = rtc?.videoSender?.parameters else { return }

       params.degradationPreference = (degradationPreference.rawValue) as NSNumber
       rtc?.videoSender?.parameters = params
    }
    
    public func disconnect() {
        for (_, webrtcClient) in self.webRTCClientMap {
            webrtcClient.disconnect()
        }
             
        self.webRTCClientMap.removeAll()
        self.webSocket?.disconnect()
        
        // remove audio notifications
        self.removeAudioNotifications()
        
        // remove audio level extractor
        self.removeAudioLevelExtractor()
        
        self.invalidateTimers()
        self.webSocket = nil
    }
    
    func sendCommand(command: String, streamId: String) {
        let command = [
            COMMAND: command,
            STREAM_ID: streamId
        ].json

        webSocket?.write(string: command)
    }
    
    public func getBroadcastObject(forStreamId id: String) {
        print("GetBroadcastObject for \(id)")

        sendCommand(
            command: GET_BROADCAST_OBJECT_COMMAND,
            streamId: id
        )
    }
    
    public func didTappedCapturePhoto() {
        webRTCClientMap[publisherStreamId ?? ""]?.didTappedCapturePhoto()
    }
    
    func invalidateTimers() {
        audioLevelGetterTimer?.invalidate()
        audioLevelGetterTimer = nil
        
        pingTimer?.invalidate()
        pingTimer = nil
        
        rtcStatsTimer?.invalidate()
        rtcStatsTimer = nil
    }
    
    deinit {
        invalidateTimers()
    }
}

extension AntMediaClient: WebRTCClientDelegate {
    func didCameraCapturedPhoto(capturedPhoto photo: UIImage) {
        self.delegate?.didCameraCapturedPhoto(capturedPhoto: photo)
    }
    
    func trackAdded(track: RTCMediaStreamTrack, stream: [RTCMediaStream]) {
        self.delegate?.trackAdded(track: track, stream: stream)
    }
    
    func trackRemoved(track: RTCMediaStreamTrack) {
        self.delegate?.trackRemoved(track: track)
    }
    
    public func sendMessage(_ message: [String: Any]) {
        self.webSocket?.write(string: message.json)
    }
    
    public func addLocalStream(streamId: String) {
        // Re-bind pending composite renderers on local stream start
        if #available(iOS 13.0, *) {
            if self.cameraMode == .dualCamera,
               let client = self.webRTCClientMap[streamId] {
                if let r = self.pendingDualFrontRenderer { client.registerCompositeLocalRenderer(r) }
                if let r = self.pendingDualBackRenderer { client.registerCompositeLocalRenderer(r) }
            }
        }
        self.delegate?.localStreamStarted(streamId: streamId)
    }
    
    public func remoteStreamAdded(streamId: String) {
        self.delegate?.remoteStreamStarted(streamId: streamId)
    }
    
    func remoteStreamRemoved(streamId: String) {
        self.delegate?.remoteStreamRemoved(streamId: streamId)
    }
    
    public func connectionStateChanged(newState: RTCIceConnectionState, streamId: String) {
        if newState == RTCIceConnectionState.closed ||
            newState == RTCIceConnectionState.disconnected ||
            newState == RTCIceConnectionState.failed {
            
            var state: String = "closed"
            
            if newState == RTCIceConnectionState.disconnected {
                state = "disconnected"
            } else {
                state = "failed"
            }
            
            print("connectionStateChanged: \(state) for stream: \(String(describing: streamId))")
            
            dispatchQueue.async {
                self.reconnectIfRequires()
                self.delegate?.disconnected(streamId: streamId)
            }
        }
    }
    
    public func dataReceivedFromDataChannel(didReceiveData data: RTCDataBuffer, streamId: String) {
        let rawJSON = String(bytes: data.data, encoding: .utf8)
        let json = rawJSON?.toJSON()
        
        if let eventType = json?[EVENT_TYPE] {
            // event happened
            if let incomingStreamId = json?[STREAM_ID] {
                
                self.delegate?.eventHappened(streamId: incomingStreamId as! String, eventType: eventType as! String)
                
                self.delegate?.eventHappened(
                    streamId: incomingStreamId as! String,
                    eventType: eventType as! String
                )
                
                self.delegate?.eventHappened(
                    streamId: incomingStreamId as! String,
                    eventType: eventType as! String,
                    payload: json
                )

            } else {
                print("Incoming message does not have streamId: \(json)")
            }
        } else {
            self.delegate?.dataReceivedFromDataChannel(streamId: streamId, data: data.data, binary: data.isBinary)
        }
    }
}

extension AntMediaClient: WebSocketDelegate {
   
    public func getPingMessage() -> [String: String] {
        return [COMMAND: "ping"]
    }
    
    public func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            isWebSocketConnected = true
            isWebSocketConnecting = false
            print("websocket is connected: \(headers)")
            self.websocketConnected()
            self.delegate?.clientDidConnect(self)
            self.webRTCClientMap[self.publisherStreamId ?? ""]?.setDefaultCameraZoomFactorIfNeeded()

            // too keep the connetion alive send ping command for every 10 seconds
            pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let jsonString = self.getPingMessage().json
                self.webSocket?.write(string: jsonString)
            }
        case let .disconnected(reason, code):
            isWebSocketConnected = false
            isWebSocketConnecting = false
            print("websocket is disconnected: \(reason) with code: \(code)")
            pingTimer?.invalidate()
            self.websocketDisconnected(message: reason, code: code)
        case .text(let string):
            // print("Received text: \(string)");
            self.onMessage(string)
        case .binary(let data):
            print("Received data: \(data.count)")
        case .ping: break
        case .pong: break
        case .viabilityChanged: break
        case .reconnectSuggested: break
        case .cancelled:
            isWebSocketConnected = false
            isWebSocketConnecting = false
            pingTimer?.invalidate()
            webSocket?.disconnect()
           
            print("Websocket is cancelled")
        case .error(let error):
            isWebSocketConnected = false
            isWebSocketConnecting = false
            pingTimer?.invalidate()
            webSocket?.disconnect()
            self.websocketDisconnected(message: String(describing: error), code: 0)
            print("Error occured on websocket connection \(String(describing: error))")
        default:
            print("Unexpected command received from websocket")
        }
    }
}

extension AntMediaClient: RTCAudioSessionDelegate {
    
    public func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        self.delegate?.audioSessionDidStartPlayOrRecord(streamId: self.getStreamId())
    }
}

/*
 This delegate used non arm64 versions. In other words it's used for RTCEAGLVideoView
 */
extension AntMediaClient: RTCVideoViewDelegate {
    
    private func resizeVideoFrame(bounds: CGRect, size: CGSize, videoView: UIView) {
    
        let defaultAspectRatio: CGSize = CGSize(width: size.width, height: size.height)
    
        let videoFrame: CGRect = AVMakeRect(aspectRatio: defaultAspectRatio, insideRect: bounds)
    
        videoView.bounds = videoFrame
    }
    
    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        print("Video size changed to " + String(Int(size.width)) + "x" + String(Int(size.height)))
        
        var bounds: CGRect?
        
        if videoView.isEqual(localView) {
            bounds = self.localContainerBounds
        } else if videoView.isEqual(remoteView) {
            bounds = self.remoteContainerBounds
        }
       
        if bounds != nil {
            resizeVideoFrame(bounds: bounds!, size: size, videoView: (videoView as? UIView)!)
        }
    }
}

// MARK: Audio interruption handling section
extension AntMediaClient {
    
    /// - Regsiters for interruption notifications
    func setupAudioNotifications() {
        
        // Get the default notification center instance.
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleInterruption),
                       name: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance())
    }
    
    /// - Unregisters for interruption notifications
    func removeAudioNotifications() {
        // Get the default notification center instance.
        let nc = NotificationCenter.default
        nc.removeObserver(self,
                          name: AVAudioSession.interruptionNotification,
                          object: AVAudioSession.sharedInstance())
    }
    
    /// - Handles audio interruptions
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        // Switch over the interruption type.
        switch type {
        case .began:
            // An interruption began. Update the UI as necessary.
            print("Audio: interruption began")
        case .ended:
            // An interruption ended. Resume playback, if appropriate.
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                // An interruption ended. Resume playback.
                print("Audio: interruption ended and should resume playback")
                activateAudioSession()
            } else {
                // An interruption ended. Don't resume playback.
                print("Audio: interruption ended and should not resume playback")
            }
        default: break
        }
    }
    
    /// - Activates the audio session
    private func activateAudioSession() {
        DispatchQueue(label: "audio").async {
            self.rtcAudioSession.lockForConfiguration()
            self.rtcAudioSession.isAudioEnabled = true
            self.rtcAudioSession.unlockForConfiguration()
            print("Audio: Activated")
        }
    }
}

// MARK: Audio level extrackting section
extension AntMediaClient {
    
    /// - Registers audio level extractor. Just starts a timer to get statistics
    public func registerAudioLevelExtractor(timeInterval: Double = 0.5) {
        audioLevelGetterTimer?.invalidate()
        audioLevelGetterTimer = Timer.scheduledTimer(timeInterval: timeInterval, target: self, selector: #selector(onAudioLevelTimerTicking), userInfo: nil, repeats: true)
    }
    
    /// - Removes audio level extractor
    public func removeAudioLevelExtractor() {
        audioLevelGetterTimer?.invalidate()
        audioLevelGetterTimer = nil
    }
    
    @objc private func onAudioLevelTimerTicking() {
        getStatistics { [weak self] statistics in
            guard let self else {
                return
            }
            let isAudioEnabled = self.webRTCClientMap[
                self.publisherStreamId ?? (self.p2pStreamId ?? "")
            ]?.isAudioEnabled() ?? false
            
            self.delegate?.audioLevelChanged(
                self,
                audioLevel: statistics.audioLevel,
                hasAudio: isAudioEnabled
            )
        }
    }
}
