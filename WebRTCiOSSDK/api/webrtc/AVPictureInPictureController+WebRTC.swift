//
//  AVPictureInPictureController+WebRTC.swift
//  WebRTCiOSSDK
//
//  Copyright © 2024 AntMedia. All rights reserved.
//

import Foundation
import AVKit
import UIKit
import WebRTC

public extension AVPictureInPictureController {
    
    /// Creates a Picture in Picture controller for WebRTC video track
    /// - Parameters:
    ///   - videoTrack: The RTCVideoTrack to display in PiP
    ///   - videoView: The video renderer view
    ///   - allowsPictureInPicturePlayback: Whether PiP is allowed
    ///   - requiresLinearPlayback: Whether linear playback is required
    ///   - canStartAutomatically: Whether PiP can start automatically when app goes to background
    /// - Returns: Configured AVPictureInPictureController or nil if PiP is not supported
    static func createForWebRTC(
        videoTrack: RTCVideoTrack,
        videoView: RTCVideoRenderer,
        allowsPictureInPicturePlayback: Bool = true,
        requiresLinearPlayback: Bool = false,
        canStartAutomatically: Bool = true
    ) -> AVPictureInPictureController? {
        
        // Check if PiP is supported
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return nil
        }
        
        // Create a dummy player layer for PiP support
        let dummyURL = URL(string: "data:video/mp4;base64,")!
        let playerItem = AVPlayerItem(url: dummyURL)
        let player = AVPlayer(playerItem: playerItem)
        let playerLayer = AVPlayerLayer(player: player)
        
        // Create PiP controller
        let pipController = AVPictureInPictureController(playerLayer: playerLayer)
        
        // Configure automatic PiP start
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = canStartAutomatically
        }
        
        // Configure the video view for PiP
        if let videoView = videoView as? UIView {
            videoView.frame = CGRect(x: 0, y: 0, width: 320, height: 240) // Default PiP size
            videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            
            // Add the WebRTC video view to the player layer's superview
            playerLayer.superlayer?.addSublayer(videoView.layer)
        }
        
        return pipController
    }
    
    /// Start Picture in Picture with WebRTC video track
    /// - Parameters:
    ///   - videoTrack: The RTCVideoTrack to display
    ///   - videoView: The video renderer view
    ///   - completion: Completion handler called when PiP starts or fails
    func startPictureInPictureWithWebRTC(
        videoTrack: RTCVideoTrack,
        videoView: RTCVideoRenderer,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        // Ensure the video track is attached to the view
        videoTrack.add(videoView)
        
        // Start PiP
        if self.isPictureInPicturePossible {
            self.startPictureInPicture()
            completion(true, nil)
        } else {
            let error = NSError(domain: "PictureInPictureError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Picture in Picture is not possible at this time"])
            completion(false, error)
        }
    }
}

// MARK: - WebRTC Video View Extensions

public extension UIView {
    
    /// Creates a WebRTC video view suitable for Picture in Picture
    /// - Parameter frame: The frame for the video view
    /// - Returns: Configured RTCVideoRenderer view
    static func createWebRTCVideoView(for frame: CGRect) -> RTCVideoRenderer {
        #if arch(arm64)
        let videoView = RTCMTLVideoView(frame: frame)
        videoView.videoContentMode = .scaleAspectFit
        #else
        let videoView = RTCEAGLVideoView(frame: frame)
        #endif
        
        videoView.frame = frame
        return videoView
    }
}

// MARK: - RTCVideoTrack Extensions

public extension RTCVideoTrack {
    
    /// Creates a Picture in Picture controller for this video track
    /// - Parameters:
    ///   - videoView: The video renderer view (optional, will create one if not provided)
    ///   - allowsPictureInPicturePlayback: Whether PiP is allowed
    ///   - requiresLinearPlayback: Whether linear playback is required
    ///   - canStartAutomatically: Whether PiP can start automatically when app goes to background
    /// - Returns: Configured AVPictureInPictureController or nil if PiP is not supported
    func createPictureInPictureController(
        videoView: RTCVideoRenderer? = nil,
        allowsPictureInPicturePlayback: Bool = true,
        requiresLinearPlayback: Bool = false,
        canStartAutomatically: Bool = true
    ) -> AVPictureInPictureController? {
        
        let rendererView = videoView ?? UIView.createWebRTCVideoView(for: CGRect(x: 0, y: 0, width: 320, height: 240))
        
        return AVPictureInPictureController.createForWebRTC(
            videoTrack: self,
            videoView: rendererView,
            allowsPictureInPicturePlayback: allowsPictureInPicturePlayback,
            requiresLinearPlayback: requiresLinearPlayback,
            canStartAutomatically: canStartAutomatically
        )
    }
}
