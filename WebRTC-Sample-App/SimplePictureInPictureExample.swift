//
//  SimplePictureInPictureExample.swift
//  WebRTC-Sample-App
//
//  Copyright © 2024 AntMedia. All rights reserved.
//

import UIKit
import WebRTCiOSSDK
import AVKit

class SimplePictureInPictureExample: UIViewController {
    
    @IBOutlet weak var localVideoView: UIView!
    @IBOutlet weak var startPiPButton: UIButton!
    @IBOutlet weak var stopPiPButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    
    private var antMediaClient: AntMediaClient?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupAntMediaClient()
    }
    
    private func setupUI() {
        title = "Simple Picture in Picture"
        
        startPiPButton.setTitle("Start PiP", for: .normal)
        stopPiPButton.setTitle("Stop PiP", for: .normal)
        stopPiPButton.isEnabled = false
        
        // Check PiP support
        if !AntMediaClient.isPictureInPictureSupported() {
            statusLabel.text = "Picture in Picture not supported on this device"
            startPiPButton.isEnabled = false
        } else {
            statusLabel.text = "Ready to start Picture in Picture"
        }
    }
    
    private func setupAntMediaClient() {
        antMediaClient = AntMediaClient()
        antMediaClient?.delegate = self
        
        // Set up video views
        antMediaClient?.setLocalView(container: localVideoView, mode: .scaleAspectFit)
    }
    
    @IBAction func startPiPButtonTapped(_ sender: UIButton) {
        antMediaClient?.startPictureInPicture { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.statusLabel.text = "Picture in Picture started!"
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
}

// MARK: - AntMediaClientDelegate

extension SimplePictureInPictureExample: AntMediaClientDelegate {
    
    func localStreamStarted(streamId: String) {
        print("Local stream started: \(streamId)")
        statusLabel.text = "Stream ready - PiP available"
    }
    
    func publishStarted(streamId: String) {
        print("Publish started: \(streamId)")
        statusLabel.text = "Publishing - PiP ready"
    }
}
