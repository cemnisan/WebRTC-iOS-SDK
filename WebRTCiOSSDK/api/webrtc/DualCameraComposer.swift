//
//  DualCameraComposer.swift
//  WebRTCiOSSDK
//
//  Created to composite front and back camera frames into a single CVPixelBuffer
//

import Foundation
import AVFoundation
import CoreImage
import CoreVideo

@available(iOS 13.0, *)
class DualCameraComposer: NSObject {
    private let session = AVCaptureMultiCamSession()
    private let processingQueue = DispatchQueue(label: "dual.camera.composer.queue")
    private let frontQueue = DispatchQueue(label: "dual.camera.front.queue")
    private let backQueue = DispatchQueue(label: "dual.camera.back.queue")
    private let context = CIContext(options: nil)

    private var frontOutput: AVCaptureVideoDataOutput?
    private var backOutput: AVCaptureVideoDataOutput?

    private var latestFrontBuffer: CMSampleBuffer?
    private var latestBackBuffer: CMSampleBuffer?

    private var targetWidth: Int
    private var targetHeight: Int
    private var fps: Int
    private var isRunning: Bool = false

    private var pixelBufferPool: CVPixelBufferPool?

    // Called with composited pixel buffer and timestamp ns
    private let onFrame: (_ pixelBuffer: CVPixelBuffer, _ timestampNs: Int64) -> Void

    init(targetWidth: Int, targetHeight: Int, fps: Int, onFrame: @escaping (_ pixelBuffer: CVPixelBuffer, _ timestampNs: Int64) -> Void) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.fps = fps
        self.onFrame = onFrame
        super.init()
    }

    func start() -> Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam is not supported on this device")
            return false
        }

        do {
            session.beginConfiguration()

            // Configure back camera (background)
            if let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                let backInput = try AVCaptureDeviceInput(device: backDevice)
                if session.canAddInput(backInput) {
                    session.addInput(backInput)
                }

                let backOutput = AVCaptureVideoDataOutput()
                backOutput.alwaysDiscardsLateVideoFrames = true
                backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if session.canAddOutput(backOutput) {
                    session.addOutput(backOutput)
                }
                self.backOutput = backOutput
                backOutput.setSampleBufferDelegate(self, queue: backQueue)
            } else {
                print("Could not get back camera for composer")
            }

            // Configure front camera (overlay)
            if let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                let frontInput = try AVCaptureDeviceInput(device: frontDevice)
                if session.canAddInput(frontInput) {
                    session.addInput(frontInput)
                }

                let frontOutput = AVCaptureVideoDataOutput()
                frontOutput.alwaysDiscardsLateVideoFrames = true
                frontOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if session.canAddOutput(frontOutput) {
                    session.addOutput(frontOutput)
                }
                self.frontOutput = frontOutput
                frontOutput.setSampleBufferDelegate(self, queue: frontQueue)
            } else {
                print("Could not get front camera for composer")
            }

            session.commitConfiguration()

            // Configure pixel buffer pool
            createPixelBufferPool(width: targetWidth, height: targetHeight)

            session.startRunning()
            isRunning = true
            return true
        } catch {
            print("DualCameraComposer start error: \(error)")
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        processingQueue.sync {
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

                // Compute PiP size and position (bottom-right)
                let pipWidth = CGFloat(self.targetWidth) * 0.3
                let aspect = frontImage.extent.height / frontImage.extent.width
                let pipHeight = pipWidth * aspect
                let pipX = CGFloat(self.targetWidth) - pipWidth - 16
                let pipY = 16.0
                let pipRect = CGRect(x: pipX, y: pipY, width: pipWidth, height: pipHeight)

                let frontScaled = frontImage.transformed(by: self.scaleToFitTransform(image: frontImage, target: pipRect.size))
                let frontPositioned = frontScaled.transformed(by: CGAffineTransform(translationX: pipRect.origin.x, y: pipRect.origin.y))
                composed = composed.composited(over: frontPositioned)
            }

            // Render
            self.context.render(composed, to: outPixel, bounds: CGRect(x: 0, y: 0, width: self.targetWidth, height: self.targetHeight), colorSpace: CGColorSpaceCreateDeviceRGB())
            CVPixelBufferUnlockBaseAddress(outPixel, [])

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


