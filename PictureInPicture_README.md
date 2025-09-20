# Picture in Picture (PiP) Implementation for WebRTC iOS SDK

This document explains how to implement and use Picture in Picture functionality in your WebRTC iOS application using the AntMedia WebRTC SDK.

## Overview

Picture in Picture (PiP) allows users to continue viewing video content in a small, floating window while using other apps. This implementation provides seamless integration with WebRTC video streams, supporting both local and remote video tracks.

## Features

- ✅ Support for local video streams (camera)
- ✅ Support for remote video streams (received video)
- ✅ Automatic PiP lifecycle management
- ✅ Delegate callbacks for PiP events
- ✅ Error handling and validation
- ✅ iOS 14+ compatibility
- ✅ Support for both MTL and EAGL video renderers

## Requirements

- iOS 14.0 or later
- Xcode 12.0 or later
- WebRTC iOS SDK
- AVKit framework

## Setup

### 1. Enable Background Modes

Add the following background modes to your `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
</array>
```

### 2. Import Required Frameworks

```swift
import AVKit
import WebRTCiOSSDK
```

## Basic Usage

### 1. Initialize and Configure

```swift
class VideoCallViewController: UIViewController {
    private var antMediaClient: AntMediaClient?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Initialize AntMediaClient
        antMediaClient = AntMediaClient()
        antMediaClient?.delegate = self
        
        // Enable Picture in Picture
        antMediaClient?.enablePictureInPicture(
            allowsPictureInPicturePlayback: true,
            requiresLinearPlayback: false
        )
    }
}
```

### 2. Start Picture in Picture

```swift
// Start PiP for local video (camera)
antMediaClient?.startPictureInPicture { success, error in
    if success {
        print("Picture in Picture started successfully")
    } else {
        print("Failed to start PiP: \(error?.localizedDescription ?? "Unknown error")")
    }
}

// Start PiP for remote video
antMediaClient?.startPictureInPictureForRemoteStream(streamId: "remote_stream_id") { success, error in
    if success {
        print("Remote Picture in Picture started successfully")
    } else {
        print("Failed to start remote PiP: \(error?.localizedDescription ?? "Unknown error")")
    }
}
```

### 3. Stop Picture in Picture

```swift
antMediaClient?.stopPictureInPicture()
```

### 4. Check PiP Status

```swift
// Check if PiP is currently active
let isActive = antMediaClient?.isPictureInPictureActive() ?? false

// Check if PiP is supported on the device
let isSupported = AntMediaClient.isPictureInPictureSupported()
```

## Delegate Methods

Implement the `AntMediaClientDelegate` methods to handle PiP events:

```swift
extension VideoCallViewController: AntMediaClientDelegate {
    
    func pictureInPictureWillStart() {
        print("Picture in Picture will start")
        // Update UI to reflect PiP state
    }
    
    func pictureInPictureDidStart() {
        print("Picture in Picture did start")
        // PiP is now active
    }
    
    func pictureInPictureWillStop() {
        print("Picture in Picture will stop")
        // PiP is about to stop
    }
    
    func pictureInPictureDidStop() {
        print("Picture in Picture did stop")
        // PiP has stopped, restore normal UI
    }
    
    func pictureInPictureFailedToStart(error: Error) {
        print("Picture in Picture failed to start: \(error.localizedDescription)")
        // Handle PiP failure
    }
    
    func pictureInPictureRestoreButtonTapped() {
        print("Picture in Picture restore button tapped")
        // User tapped restore button, bring app to foreground
    }
}
```

## Advanced Configuration

### Custom PiP Settings

```swift
// Configure PiP with custom settings
antMediaClient?.enablePictureInPicture(
    allowsPictureInPicturePlayback: true,  // Allow PiP
    requiresLinearPlayback: false          // Don't require linear playback
)
```

### Multiple Stream Support

```swift
// Start PiP for specific stream
antMediaClient?.startPictureInPicture(streamId: "specific_stream_id") { success, error in
    // Handle result
}

// Start PiP for remote stream
antMediaClient?.startPictureInPictureForRemoteStream(streamId: "remote_stream_id") { success, error in
    // Handle result
}
```

## Error Handling

The implementation includes comprehensive error handling:

- **PiP not supported**: Check device compatibility before enabling
- **PiP not enabled**: Call `enablePictureInPicture()` first
- **No video track**: Ensure video stream is active
- **No WebRTC client**: Ensure connection is established

```swift
// Check support before enabling
if AntMediaClient.isPictureInPictureSupported() {
    antMediaClient?.enablePictureInPicture()
} else {
    print("Picture in Picture not supported on this device")
}
```

## Best Practices

### 1. Enable PiP Early

Enable Picture in Picture as soon as you initialize the AntMediaClient:

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    
    antMediaClient = AntMediaClient()
    antMediaClient?.delegate = self
    
    // Enable PiP immediately
    antMediaClient?.enablePictureInPicture()
}
```

### 2. Handle PiP State Changes

Update your UI based on PiP state:

```swift
func pictureInPictureDidStart() {
    // Hide full-screen video controls
    videoControlsView.isHidden = true
    
    // Update status
    statusLabel.text = "Video in Picture in Picture mode"
}

func pictureInPictureDidStop() {
    // Show full-screen video controls
    videoControlsView.isHidden = false
    
    // Update status
    statusLabel.text = "Video in full-screen mode"
}
```

### 3. Manage App Lifecycle

Handle app state changes when PiP is active:

```swift
override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    
    // Don't disconnect if PiP is active
    if !(antMediaClient?.isPictureInPictureActive() ?? false) {
        antMediaClient?.disconnect()
    }
}
```

### 4. Clean Up Resources

```swift
deinit {
    antMediaClient?.disablePictureInPicture()
    antMediaClient?.disconnect()
}
```

## Troubleshooting

### Common Issues

1. **PiP not starting**: Ensure video stream is active and PiP is enabled
2. **Black screen in PiP**: Check that video track is properly attached
3. **PiP not supported**: Verify iOS version and device compatibility
4. **App crashes**: Ensure proper memory management and delegate handling

### Debug Tips

```swift
// Enable debug logging
AntMediaClient.setDebug(true)

// Check PiP status
print("PiP active: \(antMediaClient?.isPictureInPictureActive() ?? false)")
print("PiP supported: \(AntMediaClient.isPictureInPictureSupported())")
```

## Sample Implementation

See `PictureInPictureExampleViewController.swift` for a complete working example that demonstrates:

- PiP setup and configuration
- Starting/stopping PiP for local and remote streams
- Handling PiP delegate callbacks
- Error handling and user feedback
- UI state management

## API Reference

### AntMediaClient Methods

- `enablePictureInPicture(allowsPictureInPicturePlayback:requiresLinearPlayback:)` - Enable PiP support
- `disablePictureInPicture()` - Disable PiP support
- `startPictureInPicture(streamId:completion:)` - Start PiP for local stream
- `startPictureInPictureForRemoteStream(streamId:completion:)` - Start PiP for remote stream
- `stopPictureInPicture()` - Stop PiP
- `isPictureInPictureActive()` - Check if PiP is active
- `isPictureInPictureSupported()` - Check if PiP is supported

### Delegate Methods

- `pictureInPictureWillStart()` - Called before PiP starts
- `pictureInPictureDidStart()` - Called when PiP starts
- `pictureInPictureWillStop()` - Called before PiP stops
- `pictureInPictureDidStop()` - Called when PiP stops
- `pictureInPictureFailedToStart(error:)` - Called when PiP fails to start
- `pictureInPictureRestoreButtonTapped()` - Called when restore button is tapped

## License

This implementation is part of the AntMedia WebRTC iOS SDK and follows the same licensing terms.
