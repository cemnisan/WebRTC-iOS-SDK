//
//  DualCameraComposer.swift
//  WebRTCiOSSDK
//
//  Created to composite front and back camera frames into a single CVPixelBuffer
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo

@available(iOS 13.0, *)
class DualCameraComposer: NSObject {
    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "multiple session queue")
    private let processingQueue = DispatchQueue(label: "data output queue")
    private let context = CIContext(options: nil)

    private var frontOutput: AVCaptureVideoDataOutput?
    private var backOutput: AVCaptureVideoDataOutput?

    private var latestFrontBuffer: CMSampleBuffer?
    private var latestBackBuffer: CMSampleBuffer?

    private var targetWidth: Int
    private var targetHeight: Int
    private var fps: Int
    private var isRunning: Bool = false
    private var isStarting: Bool = false

    private var pixelBufferPool: CVPixelBufferPool?

    // PiP layout configuration (dynamic, screen-size independent)
    // X position as a fraction of output width [0,1]
    private var pipNormalizedX: CGFloat
    // Y offset from top in design points scaled by design screen height
    private var pipDesignYOffset: CGFloat
    private var pipDesignScreenHeight: CGFloat
    // PiP height as a fraction of output height [0,1]
    private var pipHeightNormalized: CGFloat
    // PiP aspect ratio (width/height)
    private var pipAspectRatio: CGFloat
    // Styling
    private var pipCornerRadius: CGFloat
    private var pipBorderWidth: CGFloat
    private var pipBorderColor: CIColor

    // Called with composited pixel buffer and timestamp ns
    private let onFrame: (_ pixelBuffer: CVPixelBuffer, _ timestampNs: Int64) -> Void

    // Select a low-cost format that supports MultiCam and target fps
    private func selectMultiCamFormat(for device: AVCaptureDevice, preferredWidth: Int = 640, preferredHeight: Int = 480, targetFps: Int) -> (format: AVCaptureDevice.Format, fps: Int)? {
        var candidates: [(AVCaptureDevice.Format, Int, Int, Int)] = [] // (format, width, height, maxFps)
        for format in device.formats {
            guard format.isMultiCamSupported else { continue }
            let desc = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Prefer NV12/420f or full-range Bi-Planar; if not available, accept others
            let ranges = format.videoSupportedFrameRateRanges
            guard let maxRange = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
            let maxFps = Int(maxRange.maxFrameRate)
            candidates.append((format, Int(desc.width), Int(desc.height), maxFps))
        }
        if candidates.isEmpty { return nil }
        // Score by closeness to preferred size, then by fps
        candidates.sort { a, b in
            let da = abs(a.1 - preferredWidth) + abs(a.2 - preferredHeight)
            let db = abs(b.1 - preferredWidth) + abs(b.2 - preferredHeight)
            if da == db { return a.3 > b.3 }
            return da < db
        }
        let best = candidates.first!
        let chosenFps = min(best.3, targetFps)
        return (best.0, chosenFps)
    }

    init(targetWidth: Int, targetHeight: Int, fps: Int, onFrame: @escaping (_ pixelBuffer: CVPixelBuffer, _ timestampNs: Int64) -> Void) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.fps = fps
        self.onFrame = onFrame
        // Defaults tuned to your design: X≈48px from left, Y≈100 on design height 906, height≈130/906, radius 10, border 3 white
        self.pipNormalizedX = CGFloat(24.0) / CGFloat(max(1, targetWidth))
        self.pipDesignYOffset = 100.0
        self.pipDesignScreenHeight = 906.0
        self.pipHeightNormalized = (130.0 / 906.0) * 1.25
        self.pipAspectRatio = 73.0 / 130.0
        self.pipCornerRadius = 10.0
        self.pipBorderWidth = 3.0
        self.pipBorderColor = CIColor(color: .white)
        super.init()
    }

    // Allow runtime configuration
    func configurePiP(normalizedX: CGFloat? = nil,
                      designYOffset: CGFloat? = nil,
                      designScreenHeight: CGFloat? = nil,
                      heightNormalized: CGFloat? = nil,
                      aspectRatio: CGFloat? = nil,
                      cornerRadius: CGFloat? = nil,
                      borderWidth: CGFloat? = nil,
                      borderColor: CGColor? = nil) {
        if let v = normalizedX { self.pipNormalizedX = v }
        if let v = designYOffset { self.pipDesignYOffset = v }
        if let v = designScreenHeight { self.pipDesignScreenHeight = v }
        if let v = heightNormalized { self.pipHeightNormalized = v }
        if let v = aspectRatio { self.pipAspectRatio = v }
        if let v = cornerRadius { self.pipCornerRadius = v }
        if let v = borderWidth { self.pipBorderWidth = v }
        if let v = borderColor { self.pipBorderColor = CIColor(cgColor: v) }
    }

    func start() -> Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam is not supported on this device")
            return false
        }

        // Prevent re-entrant starts
        if isRunning || isStarting {
            print("DualCameraComposer already running or starting; ignoring start request")
            return true
        }
        isStarting = true

        var started = false
        sessionQueue.sync {
            // Permission check
            let auth = AVCaptureDevice.authorizationStatus(for: .video)
            if auth == .denied || auth == .restricted {
                print("Camera permission not granted for MultiCam")
                self.isStarting = false
                started = false
                return
            }
            
            // Inspect available camera devices
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            print("DualCameraComposer: Available camera devices:")
            for device in discoverySession.devices {
                print("  - \(device.localizedName) (\(device.position == .front ? "front" : device.position == .back ? "back" : "unknown")) - connected: \(device.isConnected)")
            }
            
            do {
                // Prefer allowing devices to dictate format over session presets
                if self.session.canSetSessionPreset(.inputPriority) {
                    self.session.sessionPreset = .inputPriority
                }
                self.session.beginConfiguration()

            // Configure back camera (background)
            if let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                print("DualCameraComposer: Back camera device found: \(backDevice.localizedName)")
                // Configure active format and fps suitable for MultiCam
                if let chosen = selectMultiCamFormat(for: backDevice, preferredWidth: 640, preferredHeight: 480, targetFps: self.fps) {
                    do {
                        try backDevice.lockForConfiguration()
                        backDevice.activeFormat = chosen.format
                        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, chosen.fps)))
                        backDevice.activeVideoMinFrameDuration = duration
                        backDevice.activeVideoMaxFrameDuration = duration
                        backDevice.unlockForConfiguration()
                        print("DualCameraComposer: Back camera active format set to \(CMVideoFormatDescriptionGetDimensions(chosen.format.formatDescription)) @ \(chosen.fps)fps")
                    } catch {
                        print("DualCameraComposer: Failed to lock back device for configuration: \(error)")
                    }
                } else {
                    print("DualCameraComposer: No MultiCam-supported format found for back camera")
                }
                let backInput = try AVCaptureDeviceInput(device: backDevice)
                if self.session.canAddInput(backInput) {
                    self.session.addInputWithNoConnections(backInput)
                    print("DualCameraComposer: Back camera input added")
                } else {
                    print("DualCameraComposer: Cannot add back camera input")
                }

                let backOutput = AVCaptureVideoDataOutput()
                backOutput.alwaysDiscardsLateVideoFrames = true
                backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if self.session.canAddOutput(backOutput) {
                    self.session.addOutputWithNoConnections(backOutput)
                    
                    // Configure video settings
                    if backOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossy_32BGRA) {
                        backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_Lossy_32BGRA)]
                    } else if backOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossless_32BGRA) {
                        backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_Lossless_32BGRA)]
                    } else {
                        backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
                    }
                    
                    print("DualCameraComposer: Back camera output added")
                } else {
                    print("DualCameraComposer: Cannot add back camera output")
                }
                self.backOutput = backOutput
                backOutput.setSampleBufferDelegate(self, queue: self.processingQueue)
                print("DualCameraComposer: Back camera delegate set")

                // Connect back input to back output
                if let backPort = backInput.ports.first(where: { $0.mediaType == .video }) {
                    let connection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
                    connection.videoOrientation = .portrait
                    if self.session.canAddConnection(connection) {
                        self.session.addConnection(connection)
                        print("DualCameraComposer: Back camera connection added")
                    } else {
                        print("DualCameraComposer: Cannot add back camera connection")
                    }
                } else {
                    print("DualCameraComposer: Cannot find back camera video port")
                }
            } else {
                print("Could not get back camera for composer")
            }

            // Configure front camera (overlay)
            if let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                print("DualCameraComposer: Front camera device found: \(frontDevice.localizedName)")
                // Configure active format and fps suitable for MultiCam
                if let chosen = selectMultiCamFormat(for: frontDevice, preferredWidth: 640, preferredHeight: 480, targetFps: self.fps) {
                    do {
                        try frontDevice.lockForConfiguration()
                        frontDevice.activeFormat = chosen.format
                        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, chosen.fps)))
                        frontDevice.activeVideoMinFrameDuration = duration
                        frontDevice.activeVideoMaxFrameDuration = duration
                        frontDevice.unlockForConfiguration()
                        print("DualCameraComposer: Front camera active format set to \(CMVideoFormatDescriptionGetDimensions(chosen.format.formatDescription)) @ \(chosen.fps)fps")
                    } catch {
                        print("DualCameraComposer: Failed to lock front device for configuration: \(error)")
                    }
                } else {
                    print("DualCameraComposer: No MultiCam-supported format found for front camera")
                }
                let frontInput = try AVCaptureDeviceInput(device: frontDevice)
                if self.session.canAddInput(frontInput) {
                    self.session.addInputWithNoConnections(frontInput)
                    print("DualCameraComposer: Front camera input added")
                } else {
                    print("DualCameraComposer: Cannot add front camera input")
                }

                let frontOutput = AVCaptureVideoDataOutput()
                frontOutput.alwaysDiscardsLateVideoFrames = true
                frontOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if self.session.canAddOutput(frontOutput) {
                    self.session.addOutputWithNoConnections(frontOutput)
                    print("DualCameraComposer: Front camera output added")
                } else {
                    print("DualCameraComposer: Cannot add front camera output")
                }
                self.frontOutput = frontOutput
                frontOutput.setSampleBufferDelegate(self, queue: self.processingQueue)
                print("DualCameraComposer: Front camera delegate set")

                // Connect front input to front output
                if let frontPort = frontInput.ports.first(where: { $0.mediaType == .video }) {
                    let connection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
                    connection.videoOrientation = .portrait
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                    if self.session.canAddConnection(connection) {
                        self.session.addConnection(connection)
                        print("DualCameraComposer: Front camera connection added")
                    } else {
                        print("DualCameraComposer: Cannot add front camera connection")
                    }
                } else {
                    print("DualCameraComposer: Cannot find front camera video port")
                }
            } else {
                print("Could not get front camera for composer")
            }

            self.session.commitConfiguration()

            // Configure pixel buffer pool
            self.createPixelBufferPool(width: self.targetWidth, height: self.targetHeight)

            self.session.startRunning()
            
            // Wait for session to actually start running
            var attempts = 0
            let maxAttempts = 10
            while !self.session.isRunning && attempts < maxAttempts {
                Thread.sleep(forTimeInterval: 0.1)
                attempts += 1
                print("DualCameraComposer waiting for session to start... attempt \(attempts)")
            }
            
            if !self.session.isRunning {
                print("DualCameraComposer FAILED to start session - camera hardware may be locked by another session")
                started = false
                self.isStarting = false
                return
            }
            
            self.isRunning = true
            started = true
        } catch {
            started = false
        }
            self.isStarting = false
        }
        return started
    }

    func stop() {
        guard isRunning else { return }
        sessionQueue.sync {
            self.session.stopRunning()
            self.isRunning = false
            self.latestFrontBuffer = nil
            self.latestBackBuffer = nil
        }
    }

    private func createPixelBufferPool(width: Int, height: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        self.pixelBufferPool = pool
    }

    private func dequeuePixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        if status != kCVReturnSuccess {
            return nil
        }
        return pixelBufferOut
    }

    private func compositeAndSend() {
        processingQueue.async {
            guard let backSample = self.latestBackBuffer else { return }
            // Use latest front; if nil, just upscale back to target
            let frontSample = self.latestFrontBuffer

            guard let backPixel = CMSampleBufferGetImageBuffer(backSample) else { return }
            let ts = CMSampleBufferGetPresentationTimeStamp(backSample)
            let tsNs = Int64(CMTimeGetSeconds(ts) * 1_000_000_000)

            let backImage = CIImage(cvPixelBuffer: backPixel)

            guard let outPixel = self.dequeuePixelBuffer() else { return }
            CVPixelBufferLockBaseAddress(outPixel, [])
            let targetRect = CGRect(x: 0, y: 0, width: self.targetWidth, height: self.targetHeight)

            // Scale background to fit target while preserving aspect (center-crop)
            let bgScaled = backImage.transformed(by: self.scaleToFillTransform(image: backImage, target: targetRect.size))

            var composed = bgScaled

            if let frontSample = frontSample, let frontPixel = CMSampleBufferGetImageBuffer(frontSample) {
                var frontImage = CIImage(cvPixelBuffer: frontPixel)
                // Mirror front for natural selfie preview
                frontImage = frontImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: frontImage.extent.width, y: 0))

                // Compute PiP size and position dynamically
                let pipHeight = CGFloat(self.targetHeight) * self.pipHeightNormalized
                let pipWidth = self.pipAspectRatio * pipHeight
                let pipX = self.pipNormalizedX * CGFloat(self.targetWidth)
                // From top coordinate system to CI's bottom-left origin
                let yFromTop = (self.pipDesignYOffset / max(1.0, self.pipDesignScreenHeight)) * CGFloat(self.targetHeight)
                let pipY = CGFloat(self.targetHeight) - pipHeight - yFromTop
                let pipRect = CGRect(x: pipX, y: pipY, width: pipWidth, height: pipHeight)
                let innerRect = pipRect.insetBy(dx: self.pipBorderWidth, dy: self.pipBorderWidth)

                // Draw border as rounded rect
                if let borderMask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: CGRect(origin: .zero, size: pipRect.size)),
                    "inputRadius": self.pipCornerRadius + self.pipBorderWidth
                ])?.outputImage {
                    let borderColorImg = CIImage(color: self.pipBorderColor).cropped(to: CGRect(origin: .zero, size: pipRect.size))
                    let clearOuter = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: CGRect(origin: .zero, size: pipRect.size))
                    if let coloredBorder = CIFilter(name: "CIBlendWithAlphaMask", parameters: [
                        kCIInputImageKey: borderColorImg,
                        kCIInputBackgroundImageKey: clearOuter,
                        kCIInputMaskImageKey: borderMask
                    ])?.outputImage {
                        let borderTranslated = coloredBorder.transformed(by: CGAffineTransform(translationX: pipRect.origin.x, y: pipRect.origin.y))
                        composed = borderTranslated.composited(over: composed)
                    }
                }

                // Front content masked with rounded corners inside innerRect
                let frontScaled = frontImage
                    .transformed(by: self.scaleToFitTransform(image: frontImage, target: innerRect.size))
                    .cropped(to: CGRect(origin: .zero, size: innerRect.size))

                if let innerMask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: CGRect(origin: .zero, size: innerRect.size)),
                    "inputRadius": self.pipCornerRadius
                ])?.outputImage {
                    let clearInner = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: CGRect(origin: .zero, size: innerRect.size))
                    if let maskedFront = CIFilter(name: "CIBlendWithAlphaMask", parameters: [
                        kCIInputImageKey: frontScaled,
                        kCIInputBackgroundImageKey: clearInner,
                        kCIInputMaskImageKey: innerMask
                    ])?.outputImage {
                        let frontPositioned = maskedFront.transformed(by: CGAffineTransform(translationX: innerRect.origin.x, y: innerRect.origin.y))
                        composed = frontPositioned.composited(over: composed)
                    }
                }
            }

            // Render
            self.context.render(composed, to: outPixel, bounds: CGRect(x: 0, y: 0, width: self.targetWidth, height: self.targetHeight), colorSpace: CGColorSpaceCreateDeviceRGB())
            CVPixelBufferUnlockBaseAddress(outPixel, [])

            print("DualCameraComposer: Delivering composite frame to onFrame callback")
            self.onFrame(outPixel, tsNs)
        }
    }

    private func scaleToFillTransform(image: CIImage, target: CGSize) -> CGAffineTransform {
        let sx = target.width / image.extent.width
        let sy = target.height / image.extent.height
        let s = max(sx, sy)
        let tx = (target.width - image.extent.width * s) / 2
        let ty = (target.height - image.extent.height * s) / 2
        return CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    private func scaleToFitTransform(image: CIImage, target: CGSize) -> CGAffineTransform {
        let sx = target.width / image.extent.width
        let sy = target.height / image.extent.height
        let s = min(sx, sy)
        let tx = (target.width - image.extent.width * s) / 2
        let ty = (target.height - image.extent.height * s) / 2
        return CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}

@available(iOS 13.0, *)
extension DualCameraComposer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Ensure portrait orientation
        connection.videoOrientation = .portrait
        if output === backOutput {
            latestBackBuffer = sampleBuffer
            compositeAndSend()
        } else if output === frontOutput {
            latestFrontBuffer = sampleBuffer
        }
    }
}


