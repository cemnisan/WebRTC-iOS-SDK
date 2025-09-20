//
//  AutomaticPictureInPictureExample.swift
//  WebRTC-Sample-App
//
//  Copyright © 2024 AntMedia. All rights reserved.
//

import UIKit
import WebRTCiOSSDK
import AVKit

class AutomaticPictureInPictureExample: UIViewController {
    
    @IBOutlet weak var localVideoView: UIView!
    @IBOutlet weak var remoteVideoView: UIView!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var enableAutoPiPButton: UIButton!
    @IBOutlet weak var disableAutoPiPButton: UIButton!
    @IBOutlet weak var startPiPButton: UIButton!
    @IBOutlet weak var stopPiPButton: UIButton!
    
    private var antMediaClient: AntMediaClient?
    private var isAutoPiPEnabled: Bool = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupAntMediaClient()
        setupAppLifecycleObservers()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Don't disconnect if PiP is active
        if !(antMediaClient?.isPictureInPictureActive() ?? false) {
            antMediaClient?.disconnect()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupUI() {
        title = "Automatic Picture in Picture"
        
        enableAutoPiPButton.setTitle("Enable Auto PiP", for: .normal)
        disableAutoPiPButton.setTitle("Disable Auto PiP", for: .normal)
        startPiPButton.setTitle("Start PiP Manually", for: .normal)
        stopPiPButton.setTitle("Stop PiP", for: .normal)
        
        disableAutoPiPButton.isEnabled = false
        stopPiPButton.isEnabled = false
        
        // Check PiP support
        if !AntMediaClient.isPictureInPictureSupported() {
            statusLabel.text = "Picture in Picture not supported on this device"
            enableAutoPiPButton.isEnabled = false
            startPiPButton.isEnabled = false
        } else {
            statusLabel.text = "Ready to enable automatic Picture in Picture"
        }
    }
    
    private func setupAntMediaClient() {
        antMediaClient = AntMediaClient()
        antMediaClient?.delegate = self
        
        // Set up video views
        antMediaClient?.setLocalView(container: localVideoView, mode: .scaleAspectFit)
        antMediaClient?.setRemoteView(remoteContainer: remoteVideoView, mode: .scaleAspectFit)
    }
    
    private func setupAppLifecycleObservers() {
        // Listen for app going to background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // Listen for app coming to foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {
        print("App entered background")
        
        if isAutoPiPEnabled && !(antMediaClient?.isPictureInPictureActive() ?? false) {
            // Automatically start PiP when app goes to background
            antMediaClient?.startPictureInPicture { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.statusLabel.text = "Auto PiP: Started automatically in background"
                    } else {
                        self?.statusLabel.text = "Auto PiP: Failed to start automatically - \(error?.localizedDescription ?? "Unknown error")"
                    }
                }
            }
        }
    }
    
    @objc private func appWillEnterForeground() {
        print("App will enter foreground")
        
        if antMediaClient?.isPictureInPictureActive() ?? false {
            statusLabel.text = "Returning from Picture in Picture"
        }
    }
    
    // MARK: - IBActions
    
    @IBAction func enableAutoPiPButtonTapped(_ sender: UIButton) {
        antMediaClient?.enablePictureInPicture(canStartAutomatically: true)
        isAutoPiPEnabled = true
        
        statusLabel.text = "Automatic Picture in Picture enabled - will start when app goes to background"
        enableAutoPiPButton.isEnabled = false
        disableAutoPiPButton.isEnabled = true
        startPiPButton.isEnabled = true
    }
    
    @IBAction func disableAutoPiPButtonTapped(_ sender: UIButton) {
        antMediaClient?.disablePictureInPicture()
        isAutoPiPEnabled = false
        
        statusLabel.text = "Automatic Picture in Picture disabled"
        enableAutoPiPButton.isEnabled = true
        disableAutoPiPButton.isEnabled = false
        startPiPButton.isEnabled = false
        stopPiPButton.isEnabled = false
    }
    
    @IBAction func startPiPButtonTapped(_ sender: UIButton) {
        antMediaClient?.startPictureInPicture { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.statusLabel.text = "Picture in Picture started manually"
                    self?.startPiPButton.isEnabled = false
                    self?.stopPiPButton.isEnabled = true
                } else {
                    self?.statusLabel.text = "Failed to start PiP: \(error?.localizedDescription ?? "Unknown error")"
                }
            }
        }
    }
    
    @IBAction func stopPiPButtonTapped(_ sender: UIButton) {
        antMediaClient?.stopPictureInPicture()
        statusLabel.text = "Picture in Picture stopped"
        startPiPButton.isEnabled = true
        stopPiPButton.isEnabled = false
    }
    
    @IBAction func startRemotePiPButtonTapped(_ sender: UIButton) {
        // Example: Start PiP for a remote stream
        let remoteStreamId = "remote_stream_id" // Replace with actual stream ID
        
        antMediaClient?.startPictureInPictureForRemoteStream(streamId: remoteStreamId) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.statusLabel.text = "Remote Picture in Picture started"
                    self?.startPiPButton.isEnabled = false
                    self?.stopPiPButton.isEnabled = true
                } else {
                    self?.statusLabel.text = "Failed to start remote PiP: \(error?.localizedDescription ?? "Unknown error")"
                }
            }
        }
    }
}

// MARK: - AntMediaClientDelegate

extension AutomaticPictureInPictureExample: AntMediaClientDelegate {
    
    func clientDidConnect(_ client: AntMediaClient) {
        print("WebRTC client connected")
    }
    
    func clientDidDisconnect(_ message: String) {
        print("WebRTC client disconnected: \(message)")
    }
    
    func clientHasError(_ message: String) {
        print("WebRTC client error: \(message)")
        statusLabel.text = "Error: \(message)"
    }
    
    func localStreamStarted(streamId: String) {
        print("Local stream started: \(streamId)")
        statusLabel.text = "Local stream ready - Auto PiP available"
    }
    
    func remoteStreamStarted(streamId: String) {
        print("Remote stream started: \(streamId)")
        statusLabel.text = "Remote stream ready - Auto PiP available"
    }
    
    func publishStarted(streamId: String) {
        print("Publish started: \(streamId)")
        statusLabel.text = "Publishing - Auto PiP ready"
    }
    
    func playStarted(streamId: String) {
        print("Play started: \(streamId)")
        statusLabel.text = "Playing - Auto PiP ready"
    }
}
