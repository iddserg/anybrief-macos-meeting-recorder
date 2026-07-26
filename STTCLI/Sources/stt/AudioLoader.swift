import AudioToolbox
import Foundation

extension AudioProcessor {
    /// Decode supported Core Audio files directly to 16 kHz mono Float32 samples.
    ///
    /// FluidAudio's `AudioConverter.resampleAudioFile` polls
    /// `AVAudioFile.framePosition`. For some valid VBR MP3 files AVFAudio can
    /// raise an Objective-C exception from that property, which bypasses Swift
    /// error handling and aborts the process. ExtAudioFile performs the same
    /// decode/resample operation through an OSStatus-based API.
    func loadAudioSamples(from url: URL) throws -> [Float] {
        verboseLog("🎵 Loading audio: \(url.lastPathComponent)")

        var audioFile: ExtAudioFileRef?
        try check(
            ExtAudioFileOpenURL(url as CFURL, &audioFile),
            operation: "opening \(url.lastPathComponent)"
        )
        guard let audioFile else {
            throw AudioLoadingError.missingAudioFile
        }
        defer {
            ExtAudioFileDispose(audioFile)
        }

        var targetFormat = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try withUnsafePointer(to: &targetFormat) { formatPointer in
            try check(
                ExtAudioFileSetProperty(
                    audioFile,
                    kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                    formatPointer
                ),
                operation: "configuring audio conversion"
            )
        }

        let chunkFrameCount: UInt32 = 16_000
        var chunk = [Float](repeating: 0, count: Int(chunkFrameCount))
        var samples: [Float] = []

        while true {
            var framesRead = chunkFrameCount
            let status = chunk.withUnsafeMutableBytes { bytes -> OSStatus in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(bytes.count),
                        mData: bytes.baseAddress
                    )
                )
                return ExtAudioFileRead(audioFile, &framesRead, &bufferList)
            }
            try check(status, operation: "decoding audio")

            guard framesRead > 0 else {
                break
            }
            samples.append(contentsOf: chunk.prefix(Int(framesRead)))
        }

        guard !samples.isEmpty else {
            throw ProcessingError.unsupportedFormat
        }
        let duration = Double(samples.count) / 16_000.0
        verboseLog(
            "📊 Loaded \(samples.count) samples (\(String(format: "%.1f", duration))s at 16 kHz mono)"
        )
        return samples
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioLoadingError.operationFailed(operation: operation, status: status)
        }
    }
}

enum AudioLoadingError: LocalizedError {
    case missingAudioFile
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            return "Core Audio did not return an audio file handle."
        case let .operationFailed(operation, status):
            let detail = NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status)
            ).localizedDescription
            return "Core Audio failed while \(operation): \(detail) (OSStatus \(status))."
        }
    }
}
