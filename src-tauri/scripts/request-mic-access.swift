import AVFoundation
import Foundation

let status = AVCaptureDevice.authorizationStatus(for: .audio)
switch status {
case .authorized:
    print("authorized")
case .denied, .restricted:
    print("denied")
case .notDetermined:
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { g in
        granted = g
        semaphore.signal()
    }
    semaphore.wait()
    print(granted ? "authorized" : "denied")
@unknown default:
    print("unknown")
}
