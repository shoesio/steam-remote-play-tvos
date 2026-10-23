import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

public struct EncodedVideoFrame: Sendable {
    public let codec: SteamVideoCodec
    public let data: Data
    public let presentationTime: CMTime
    public init(codec: SteamVideoCodec, data: Data, presentationTime: CMTime) {
        self.codec = codec; self.data = data; self.presentationTime = presentationTime
    }
}

/// Called on one serial media queue; output may arrive on VideoToolbox's queue.
public protocol VideoDecoder: AnyObject {
    func submit(_ frame: EncodedVideoFrame) throws
    func reset()
}
public enum VideoDecoderError: Error { case unsupportedCodec, malformedFrame, missingParameterSets, status(OSStatus) }

public final class HEVCVideoDecoder: VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: [UInt8: Data] = [:]
    private var configuredParameters: [UInt8: Data] = [:]
    private let output: (Result<CVPixelBuffer, Error>) -> Void
    public init(output: @escaping (Result<CVPixelBuffer, Error>) -> Void) { self.output = output }
    deinit { reset() }
    public func reset() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; parameters = [:]; configuredParameters = [:]
    }
    public func submit(_ frame: EncodedVideoFrame) throws {
        guard frame.codec == .hevc else { throw VideoDecoderError.unsupportedCodec }
        guard frame.data.count <= 2 * 1024 * 1024 else { throw VideoDecoderError.malformedFrame }
        let nals = SteamHEVCAssembler.annexBNALs(frame.data)
        guard !nals.isEmpty, nals.count <= 256, nals.allSatisfy({ $0.count >= 2 }) else { throw VideoDecoderError.malformedFrame }
        for nal in nals {
            let type = (nal[0] >> 1) & 63
            if (32...34).contains(type) { parameters[type] = nal }
        }
        guard let vps = parameters[32], let sps = parameters[33], let pps = parameters[34] else { throw VideoDecoderError.missingParameterSets }
        if session == nil || parameters != configuredParameters {
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
            session = nil; format = nil
            let result = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                var pointers = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [vps.count, sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 3, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            } } }
            try check(result)
            let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
            try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format!,
                decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session))
            configuredParameters = parameters
        }
        var sample = Data()
        for nal in nals where ((nal[0] >> 1) & 63) < 32 {
            let length = UInt32(nal.count)
            sample += Data([UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
            sample += nal
        }
        guard !sample.isEmpty else { return }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0, blockBufferOut: &block))
        try sample.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: frame.presentationTime, decodeTimeStamp: .invalid)
        var size = sample.count
        var buffer: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer))
        let output = self.output
        try check(VTDecompressionSessionDecodeFrame(session!, sampleBuffer: buffer!, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { output(.success(image)) }
            else { output(.failure(VideoDecoderError.status(status))) }
        })
    }
    public func waitForPendingFrames() { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) } }
    private func check(_ status: OSStatus) throws { if status != noErr { throw VideoDecoderError.status(status) } }
}
