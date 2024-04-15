import AVFoundation
import Foundation

@available(tvOS 17.0, *)
protocol IOCaptureUnit {
    associatedtype Output: AVCaptureOutput

    var input: AVCaptureInput? { get set }
    var output: Output? { get set }
    var connection: AVCaptureConnection? { get set }

    init(_ track: UInt8)
}
