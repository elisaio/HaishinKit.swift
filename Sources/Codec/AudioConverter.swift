import AVFoundation

protocol AudioConverterDelegate: class {
    func didSetFormatDescription(audio formatDescription: CMFormatDescription?)
    func sampleOutput(audio bytes: UnsafePointer<UInt8>?, count: UInt32, presentationTimeStamp: CMTime)
}

// MARK: -
/**
 - seealse:
  - https://developer.apple.com/library/ios/technotes/tn2236/_index.html
 */
final class AudioConverter: NSObject {
    enum Error: Swift.Error {
        case setPropertyError(id: AudioConverterPropertyID, status: OSStatus)
    }

    enum Destination {
        case AAC
        case PCM

        var formatID: AudioFormatID {
            switch self {
            case .AAC:
                return kAudioFormatMPEG4AAC
            case .PCM:
                return kAudioFormatLinearPCM
            }
        }

        var formatFlags: UInt32 {
            switch self {
            case .AAC:
                return UInt32(MPEG4ObjectID.AAC_LC.rawValue)
            case .PCM:
                return kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger
            }
        }

        var framesPerPacket: UInt32 {
            switch self {
            case .AAC:
                return 1024
            case .PCM:
                return 1
            }
        }

        var bitsPerChannel: UInt32 {
            switch self {
            case .AAC:
                return 0
            case .PCM:
                return 16
            }
        }

        var inClassDescriptions: [AudioClassDescription] {
            switch self {
            case .AAC:
                #if os(iOS)
                return [
                    AudioClassDescription(mType: kAudioEncoderComponentType, mSubType: kAudioFormatMPEG4AAC, mManufacturer: kAppleSoftwareAudioCodecManufacturer),
                    AudioClassDescription(mType: kAudioEncoderComponentType, mSubType: kAudioFormatMPEG4AAC, mManufacturer: kAppleHardwareAudioCodecManufacturer)
                ]
                #else
                return []
                #endif
            case .PCM:
                return []
            }
        }

        func bytePerFrame(_ channel: UInt32) -> UInt32 {
            switch self {
            case .AAC:
                return 0
            case .PCM:
                return channel * 2
            }
        }

        func audioStreamBasicDescription(_ inSourceFormat: AudioStreamBasicDescription?, sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription? {
            guard let inSourceFormat = inSourceFormat else { return nil }
            let destinationChannels: UInt32 = (channels == 0) ? inSourceFormat.mChannelsPerFrame : channels
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate == 0 ? inSourceFormat.mSampleRate : sampleRate,
                mFormatID: formatID,
                mFormatFlags: formatFlags,
                mBytesPerPacket: bytePerFrame(destinationChannels),
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: bytePerFrame(destinationChannels),
                mChannelsPerFrame: destinationChannels,
                mBitsPerChannel: bitsPerChannel,
                mReserved: 0
            )
        }
    }

    static let supportedSettingsKeys: [String] = [
        "muted",
        "bitrate",
        "sampleRate", // down,up sampleRate not supported yet #58
        "actualBitrate"
    ]

    static let minimumBitrate: UInt32 = 8 * 1024
    static let defaultBitrate: UInt32 = 32 * 1024
    // 0 means according to a input source
    static let defaultChannels: UInt32 = 0
    // 0 means according to a input source
    static let defaultSampleRate: Double = 0
    static let defaultMaximumBuffers: Int = 1
    static let defaultBufferListSize: Int = AudioBufferList.sizeInBytes(maximumBuffers: 1)

    var destination: Destination = .AAC

    @objc var muted: Bool = false

    @objc var bitrate: UInt32 = AudioConverter.defaultBitrate {
        didSet {
            guard bitrate != oldValue else {
                return
            }
            lockQueue.async {
                if let format = self._inDestinationFormat {
                    self.setBitrateUntilNoErr(self.bitrate * format.mChannelsPerFrame)
                }
            }
        }
    }
    @objc var sampleRate: Double = AudioConverter.defaultSampleRate
    @objc var actualBitrate: UInt32 = AudioConverter.defaultBitrate {
        didSet {
            logger.info("\(actualBitrate)")
        }
    }

    var channels: UInt32 = AudioConverter.defaultChannels
    var formatDescription: CMFormatDescription? {
        didSet {
            if !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: oldValue) {
                delegate?.didSetFormatDescription(audio: formatDescription)
            }
        }
    }
    var lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioConverter.lock")
    weak var delegate: AudioConverterDelegate?
    internal(set) var isRunning: Bool = false
    private var maximumBuffers: Int = AudioConverter.defaultMaximumBuffers
    private var bufferListSize: Int = AudioConverter.defaultBufferListSize
    private var currentBufferList: UnsafeMutableAudioBufferListPointer?
    private var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            logger.info("\(String(describing: self.inSourceFormat))")
            guard let inSourceFormat: AudioStreamBasicDescription = self.inSourceFormat else {
                return
            }
            let nonInterleaved: Bool = inSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            maximumBuffers = nonInterleaved ? Int(inSourceFormat.mChannelsPerFrame) : AudioConverter.defaultMaximumBuffers
            bufferListSize = nonInterleaved ? AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers) : AudioConverter.defaultBufferListSize
        }
    }
    private var _inDestinationFormat: AudioStreamBasicDescription?
    private var inDestinationFormat: AudioStreamBasicDescription {
        get {
            if _inDestinationFormat == nil {
                _inDestinationFormat = destination.audioStreamBasicDescription(inSourceFormat, sampleRate: sampleRate, channels: channels)
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &_inDestinationFormat!, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
                )
            }
            return _inDestinationFormat!
        }
        set {
            _inDestinationFormat = newValue
        }
    }

    private var inputDataProc: AudioConverterComplexInputDataProc = {(
        converter: AudioConverterRef,
        ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
        inUserData: UnsafeMutableRawPointer?) in
        return Unmanaged<AudioConverter>.fromOpaque(inUserData!).takeUnretainedValue().onInputDataForAudioConverter(
            ioNumberDataPackets,
            ioData: ioData,
            outDataPacketDescription: outDataPacketDescription
        )
    }

    private var _converter: AudioConverterRef?
    private var converter: AudioConverterRef {
        var status: OSStatus = noErr
        if _converter == nil {
            var inClassDescriptions = destination.inClassDescriptions
            status = AudioConverterNewSpecific(
                &inSourceFormat!,
                &inDestinationFormat,
                UInt32(inClassDescriptions.count),
                &inClassDescriptions,
                &_converter
            )
            setBitrateUntilNoErr(bitrate * inDestinationFormat.mChannelsPerFrame)
        }
        if status != noErr {
            logger.warn("\(status)")
        }
        return _converter!
    }

    func encodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let format: CMAudioFormatDescription = sampleBuffer.formatDescription, isRunning else {
            return
        }

        if inSourceFormat == nil {
            inSourceFormat = format.streamBasicDescription?.pointee
        }

        var blockBuffer: CMBlockBuffer?
        currentBufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: currentBufferList!.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        if blockBuffer == nil {
            logger.warn("IllegalState for blockBuffer")
            return
        }

        if muted {
            for i in 0..<currentBufferList!.count {
                memset(currentBufferList![i].mData, 0, Int(currentBufferList![i].mDataByteSize))
            }
        }

        var finished: Bool = false
        repeat {
            var ioOutputDataPacketSize: UInt32 = 1
            let dataLength: Int = blockBuffer!.dataLength

            let outOutputData: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: 1)
            outOutputData[0].mNumberChannels = inDestinationFormat.mChannelsPerFrame
            outOutputData[0].mDataByteSize = UInt32(dataLength)
            outOutputData[0].mData = UnsafeMutableRawPointer.allocate(byteCount: dataLength, alignment: 0)

            let status: OSStatus = AudioConverterFillComplexBuffer(
                converter,
                inputDataProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &ioOutputDataPacketSize,
                outOutputData.unsafeMutablePointer,
                nil
            )

            switch status {
            // kAudioConverterErr_InvalidInputSize: perhaps mistake. but can support macOS BuiltIn Mic #61
            case noErr, kAudioConverterErr_InvalidInputSize:
                delegate?.sampleOutput(
                    audio: outOutputData[0].mData?.assumingMemoryBound(to: UInt8.self),
                    count: outOutputData[0].mDataByteSize,
                    presentationTimeStamp: sampleBuffer.presentationTimeStamp
                )
            case -1:
                finished = true
            default:
                finished = true
            }

            for i in 0..<outOutputData.count {
                free(outOutputData[i].mData)
            }

            free(outOutputData.unsafeMutablePointer)
        } while !finished
    }

    func invalidate() {
        lockQueue.async {
            self.inSourceFormat = nil
            self._inDestinationFormat = nil
            if let converter: AudioConverterRef = self._converter {
                AudioConverterDispose(converter)
            }
            self._converter = nil
        }
    }

    func onInputDataForAudioConverter(
        _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {

        guard let bufferList: UnsafeMutableAudioBufferListPointer = currentBufferList else {
            ioNumberDataPackets.pointee = 0
            return -1
        }

        memcpy(ioData, bufferList.unsafePointer, bufferListSize)
        ioNumberDataPackets.pointee = 1
        free(bufferList.unsafeMutablePointer)
        currentBufferList = nil

        return noErr
    }

    private func setBitrateUntilNoErr(_ bitrate: UInt32) {
        do {
            try setProperty(id: kAudioConverterEncodeBitRate, data: bitrate * inDestinationFormat.mChannelsPerFrame)
            actualBitrate = bitrate
        } catch {
            if AudioConverter.minimumBitrate < bitrate {
                setBitrateUntilNoErr(bitrate - AudioConverter.minimumBitrate)
            } else {
                actualBitrate = AudioConverter.minimumBitrate
            }
        }
    }

    private func setProperty<T>(id: AudioConverterPropertyID, data: T) throws {
        guard let converter: AudioConverterRef = _converter else {
            return
        }
        let size = UInt32(MemoryLayout<T>.size)
        var buffer = data
        let status = AudioConverterSetProperty(converter, id, size, &buffer)
        guard status == 0 else {
            throw Error.setPropertyError(id: id, status: status)
        }
    }
}

extension AudioConverter: Running {
    // MARK: Running
    func startRunning() {
        lockQueue.async {
            self.isRunning = true
        }
    }
    func stopRunning() {
        lockQueue.async {
            if let convert: AudioQueueRef = self._converter {
                AudioConverterDispose(convert)
                self._converter = nil
            }
            self.inSourceFormat = nil
            self.formatDescription = nil
            self._inDestinationFormat = nil
            self.currentBufferList = nil
            self.isRunning = false
        }
    }
}
