# Picture in Picture with Extensions - WebRTC iOS SDK

This implementation uses Apple's native `AVPictureInPictureController` with Swift extensions to provide a clean, simple Picture in Picture solution for WebRTC video streams.

## Overview

Instead of creating custom managers, this approach extends Apple's `AVPictureInPictureController` with WebRTC-specific functionality, making it easier to integrate and maintain.

## Key Benefits

- ✅ **Native Apple API** - Uses `AVPictureInPictureController` directly
- ✅ **Automatic PiP** - Can start automatically when app goes to background
- ✅ **Simple Extensions** - Clean Swift extensions for WebRTC integration
- ✅ **Minimal Code** - No custom managers or complex abstractions
- ✅ **Easy Integration** - Drop-in functionality for existing apps
- ✅ **Maintainable** - Leverages Apple's well-tested PiP implementation

## Files Added

1. **`AVPictureInPictureController+WebRTC.swift`** - Extensions for WebRTC integration
2. **Enhanced `AntMediaClient.swift`** - Added simple PiP methods
3. **`SimplePictureInPictureExample.swift`** - Basic usage example

## Quick Start

### 1. Automatic Picture in Picture (Recommended)

```swift
class VideoCallViewController: UIViewController {
    private var antMediaClient: AntMediaClient?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        antMediaClient = AntMediaClient()
        antMediaClient?.delegate = self
        
        // Enable automatic PiP - starts when app goes to background
        antMediaClient?.enablePictureInPicture(canStartAutomatically: true)
        
        // Set up video view
        antMediaClient?.setLocalView(container: localVideoView, mode: .scaleAspectFit)
    }
    
    // PiP will start automatically when app goes to background
    // No manual button needed!
}
```

### 2. Manual Picture in Picture

```swift
class VideoCallViewController: UIViewController {
    private var antMediaClient: AntMediaClient?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        antMediaClient = AntMediaClient()
        antMediaClient?.delegate = self
        
        // Enable PiP but don't start automatically
        antMediaClient?.enablePictureInPicture(canStartAutomatically: false)
        
        // Set up video view
        antMediaClient?.setLocalView(container: localVideoView, mode: .scaleAspectFit)
    }
    
    @IBAction func startPiPTapped(_ sender: UIButton) {
        antMediaClient?.startPictureInPicture { success, error in
            if success {
                print("Picture in Picture started!")
            } else {
                print("Failed: \(error?.localizedDescription ?? "Unknown error")")
            }
        }
    }
    
    @IBAction func stopPiPTapped(_ sender: UIButton) {
        antMediaClient?.stopPictureInPicture()
    }
}
```

### 3. For Remote Streams

```swift
// Start PiP for a specific remote stream
antMediaClient?.startPictureInPictureForRemoteStream(streamId: "remote_stream_id") { success, error in
    // Handle result
}
```

### 4. Check PiP Status

```swift
// Check if PiP is active
let isActive = antMediaClient?.isPictureInPictureActive() ?? false

// Check if PiP is supported
let isSupported = AntMediaClient.isPictureInPictureSupported()
```

## API Reference

### AntMediaClient Methods

```swift
// Enable PiP with automatic activation
func enablePictureInPicture(canStartAutomatically: Bool = true)

// Disable PiP
func disablePictureInPicture()

// Start PiP for local stream
func startPictureInPicture(streamId: String = "", completion: @escaping (Bool, Error?) -> Void)

// Start PiP for remote stream
func startPictureInPictureForRemoteStream(streamId: String, completion: @escaping (Bool, Error?) -> Void)

// Stop PiP
func stopPictureInPicture()

// Check if PiP is active
func isPictureInPictureActive() -> Bool

// Check if PiP is supported
static func isPictureInPictureSupported() -> Bool
```

### Extension Methods

```swift
// Create PiP controller for RTCVideoTrack
func createPictureInPictureController(
    videoView: RTCVideoRenderer? = nil,
    allowsPictureInPicturePlayback: Bool = true,
    requiresLinearPlayback: Bool = false
) -> AVPictureInPictureController?

// Start PiP with WebRTC video track
func startPictureInPictureWithWebRTC(
    videoTrack: RTCVideoTrack,
    videoView: RTCVideoRenderer,
    completion: @escaping (Bool, Error?) -> Void
)
```

## Automatic Picture in Picture

### How Automatic PiP Works

When `canStartAutomatically` is set to `true`, the PiP controller uses Apple's `canStartPictureInPictureAutomaticallyFromInline` property. This means:

1. **App goes to background** → PiP starts automatically
2. **User switches apps** → Video continues in PiP window
3. **User returns to app** → PiP stops, video returns to full screen
4. **No manual intervention** → Seamless user experience

### Configuration Options

```swift
// Enable automatic PiP (recommended for video calls)
antMediaClient?.enablePictureInPicture(canStartAutomatically: true)

// Enable PiP but require manual start
antMediaClient?.enablePictureInPicture(canStartAutomatically: false)

// Disable PiP completely
antMediaClient?.disablePictureInPicture()
```

### App Lifecycle Handling

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    
    // Enable automatic PiP
    antMediaClient?.enablePictureInPicture(canStartAutomatically: true)
    
    // Listen for app lifecycle changes
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidEnterBackground),
        name: UIApplication.didEnterBackgroundNotification,
        object: nil
    )
}

@objc private func appDidEnterBackground() {
    // PiP will start automatically if enabled
    print("App went to background - PiP should start automatically")
}
```

## How It Works

### 1. Extension Approach

The `AVPictureInPictureController+WebRTC.swift` extension adds:

- **`createForWebRTC`** - Static method to create PiP controller for WebRTC
- **`startPictureInPictureWithWebRTC`** - Method to start PiP with WebRTC video
- **`RTCVideoTrack` extension** - Adds `createPictureInPictureController` method
- **`UIView` extension** - Helper to create WebRTC video views

### 2. Integration Flow

1. **Get Video Track** - Extract `RTCVideoTrack` from WebRTC client
2. **Create PiP Controller** - Use extension to create `AVPictureInPictureController`
3. **Start PiP** - Call native `startPictureInPicture()` method
4. **Handle Events** - Use standard `AVPictureInPictureControllerDelegate`

### 3. Video Rendering

The extension creates a dummy `AVPlayerLayer` for PiP support and overlays the WebRTC video view on top, ensuring seamless video display in Picture in Picture mode.

## Requirements

- iOS 14.0+
- Xcode 12.0+
- AVKit framework
- WebRTC iOS SDK

## Setup

### 1. Add Background Modes

Add to your `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
</array>
```

### 2. Import Frameworks

```swift
import AVKit
import WebRTCiOSSDK
```

## Advanced Usage

### Custom Video View

```swift
// Create custom video view for PiP
let customVideoView = UIView.createWebRTCVideoView(for: CGRect(x: 0, y: 0, width: 320, height: 240))

// Use with video track
let pipController = videoTrack.createPictureInPictureController(videoView: customVideoView)
```

### Direct Extension Usage

```swift
// Use extensions directly without AntMediaClient
let pipController = AVPictureInPictureController.createForWebRTC(
    videoTrack: videoTrack,
    videoView: videoView
)

pipController?.startPictureInPictureWithWebRTC(
    videoTrack: videoTrack,
    videoView: videoView
) { success, error in
    // Handle result
}
```

## Error Handling

The implementation includes comprehensive error handling:

- **PiP not supported** - Check device compatibility
- **No video track** - Ensure stream is active
- **No WebRTC client** - Verify connection
- **PiP not possible** - Handle timing issues

```swift
antMediaClient?.startPictureInPicture { success, error in
    if success {
        // PiP started successfully
    } else {
        // Handle error
        switch error?.code {
        case -1:
            print("No WebRTC client found")
        case -2:
            print("No video track available")
        case -3:
            print("Failed to create PiP controller")
        default:
            print("Unknown error: \(error?.localizedDescription ?? "")")
        }
    }
}
```

## Best Practices

### 1. Check Support First

```swift
guard AntMediaClient.isPictureInPictureSupported() else {
    print("PiP not supported on this device")
    return
}
```

### 2. Handle App Lifecycle

```swift
override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    
    // Don't disconnect if PiP is active
    if !(antMediaClient?.isPictureInPictureActive() ?? false) {
        antMediaClient?.disconnect()
    }
}
```

### 3. Clean Up Resources

```swift
deinit {
    antMediaClient?.stopPictureInPicture()
    antMediaClient?.disconnect()
}
```

## Troubleshooting

### Common Issues

1. **Black screen in PiP** - Ensure video track is properly attached
2. **PiP not starting** - Check that video stream is active
3. **App crashes** - Verify proper memory management

### Debug Tips

```swift
// Enable debug logging
AntMediaClient.setDebug(true)

// Check PiP status
print("PiP active: \(antMediaClient?.isPictureInPictureActive() ?? false)")
print("PiP supported: \(AntMediaClient.isPictureInPictureSupported())")
```

## Comparison with Custom Manager Approach

| Aspect | Extension Approach | Custom Manager |
|--------|-------------------|----------------|
| **Complexity** | Simple | Complex |
| **Maintenance** | Low | High |
| **Apple Integration** | Native | Custom |
| **Code Size** | Small | Large |
| **Flexibility** | Good | Excellent |
| **Learning Curve** | Easy | Moderate |

## Conclusion

The extension-based approach provides a clean, simple way to add Picture in Picture functionality to your WebRTC iOS app. It leverages Apple's native APIs while providing WebRTC-specific convenience methods, making it easy to integrate and maintain.

This approach is recommended for most use cases where you need basic PiP functionality without complex customization requirements.
