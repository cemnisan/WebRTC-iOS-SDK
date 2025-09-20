// Import required frameworks
import Foundation
import WebRTC
import AVKit
import VideoToolbox
import Accelerate

// Define closure type for handling CMSampleBuffer, orientation, scaleFactor, and userID
public typealias CMSampleBufferRenderer = (CMSampleBuffer, CGImagePropertyOrientation, CGFloat, Int) -> ()

// Define closure variables for handling CMSampleBuffer from FrameRenderer
public var getCMSampleBufferFromFrameRenderer: CMSampleBufferRenderer = { _,_,_,_ in }
public var getCMSampleBufferFromFrameRendererForPIP: CMSampleBufferRenderer = { _,_,_,_ in }
public var getLocalVideoCMSampleBufferFromFrameRenderer:
CMSampleBufferRenderer = { _,_,_,_ in }

// Define the FrameRenderer class responsible for rendering video frames
public class FrameRenderer: NSObject, RTCVideoRenderer {
    // VARIABLES
    var scaleFactor: CGFloat?
    var recUserID: Int = 0
    var frameImage = UIImage()
    var videoFormatDescription: CMFormatDescription?
    var didGetFrame: ((CMSampleBuffer) -> ())?
    private var ciContext = CIContext()
    
    init(uID: Int) {
        super.init()
        recUserID = uID
    }
    
    // Set the aspect ratio based on the size
    public func setSize(_ size: CGSize) {
        self.scaleFactor = size.height > size.width ? size.height / size.width : size.width / size.height
    }
    
    // Render a video frame received from WebRTC
    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let pixelBuffer = self.getCVPixelBuffer(frame: frame) else {
            return
        }
        
        // Extract timing information from the frame and create a CMSampleBuffer
        let timingInfo = covertFrameTimestampToTimingInfo(frame: frame)!
        let cmSampleBuffer = self.createSampleBufferFrom(pixelBuffer: pixelBuffer, timingInfo: timingInfo)!
        
        // Determine the video orientation and handle the CMSampleBuffer accordingly
        let oriented: CGImagePropertyOrientation?
        switch frame!.rotation.rawValue {
        case RTCVideoRotation._0.rawValue:
            oriented = .right
        case RTCVideoRotation._90.rawValue:
            oriented = .right
        case RTCVideoRotation._180.rawValue:
            oriented = .right
        case RTCVideoRotation._270.rawValue:
            oriented = .left
        default:
            oriented = .right
        }
        
        getCMSampleBufferFromFrameRenderer(cmSampleBuffer, oriented!, self.scaleFactor!, self.recUserID)
        getCMSampleBufferFromFrameRendererForPIP(cmSampleBuffer, oriented!, self.scaleFactor!, self.recUserID)
        
        // Call the didGetFrame closure if it exists
        if let closure = didGetFrame {
            closure(cmSampleBuffer)
        }
    }
    
    // Function to create a CVPixelBuffer from a CIImage
    public func createPixelBufferFrom(image: CIImage) -> CVPixelBuffer? {
        if #available(iOS 15.0, *) {
            let attrs = [
                kCVPixelBufferCGImageCompatibilityKey: false,
                kCVPixelBufferCGBitmapContextCompatibilityKey: false,
                kCVPixelBufferWidthKey: Int(image.extent.width),
                kCVPixelBufferHeightKey: Int(image.extent.height)
            ] as CFDictionary
            
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
            
            if status == kCVReturnSuccess {
                self.ciContext.render(image, to: pixelBuffer!)
                return pixelBuffer
            } else {
                // Failed to create a CVPixelBuffer
                return nil
            }
        }
        return nil
    }
    
    // Function to create a CVPixelBuffer from a CIImage using an existing CVPixelBuffer
    public func buffer(from image: CIImage, oldCVPixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        
        if status == kCVReturnSuccess {
            oldCVPixelBuffer.propagateAttachments(to: pixelBuffer!)
            return pixelBuffer
        } else {
            // Failed to create a CVPixelBuffer
            return nil
        }
    }
    
    /// Convert RTCVideoFrame to CVPixelBuffer
    public func getCVPixelBuffer(frame: RTCVideoFrame?) -> CVPixelBuffer? {
        var buffer : RTCCVPixelBuffer?
        var pixelBuffer: CVPixelBuffer?
        
        if let inputBuffer = frame?.buffer {
            if let iBuffer = inputBuffer as? RTCI420Buffer {
                if let cvPixelBuffer = convertToCVPixelBuffer(withI420Buffer: iBuffer) {
                    // Use the cvPixelBuffer as an RTCCVPixelBuffer
                    // ...
                    pixelBuffer = cvPixelBuffer
                    return pixelBuffer
                }
                return convertToCVPixelBuffer(withI420Buffer: iBuffer)
            }
        }
        
        buffer = frame?.buffer as? RTCCVPixelBuffer
        pixelBuffer = buffer?.pixelBuffer
        return pixelBuffer
    }
    /// Convert RTCVideoFrame to CMSampleTimingInfo
    public func covertFrameTimestampToTimingInfo(frame: RTCVideoFrame?) -> CMSampleTimingInfo? {
        let scale = CMTimeScale(NSEC_PER_SEC)
        let pts = CMTime(value: CMTimeValue(Double(frame!.timeStamp) * Double(scale)), timescale: scale)
        let timingInfo = CMSampleTimingInfo(duration: CMTime.invalid,
                                            presentationTimeStamp: pts,
                                            decodeTimeStamp: CMTime.invalid)
        return timingInfo
    }
    
    /// Convert CVPixelBuffer to CMSampleBuffer
    public func createSampleBufferFrom(pixelBuffer: CVPixelBuffer, timingInfo: CMSampleTimingInfo) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        
        var timimgInfo = timingInfo
        var formatDescription: CMFormatDescription? = nil
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        
        let osStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timimgInfo,
            sampleBufferOut: &sampleBuffer
        )
        

        guard let buffer = sampleBuffer else {
            return nil
        }
        
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)! as NSArray
        let dict: NSMutableDictionary = attachments[0] as! NSMutableDictionary
        dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true as NSNumber
        
        return buffer
    }
    
    public func convertToCVPixelBuffer(withI420Buffer buffer: RTCI420Buffer) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(buffer.width),
            Int(buffer.height),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            pixelBufferAttributes as CFDictionary,
            &pixelBuffer
        )
        
        guard result == kCVReturnSuccess else {
            return nil
        }
        
        guard let pixelBuffer = pixelBuffer else {
            return nil
        }
        
        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        
        guard lockResult == kCVReturnSuccess else {
            print("convertToCVPixelBufferWithI420Buffer result = \(lockResult)")
            return nil
        }
        
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        
        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        
        let dstStrideY = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        
        guard let dstUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }
        
        let dstStrideUV = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
        
        return pixelBuffer
    }
}

