import Foundation
import AudioToolbox

public enum AudioDecoderError: Error { case unsupportedConfiguration, malformedPacket, status(OSStatus) }

/// Native Opus decoder. Serialized by the caller; outputs interleaved float stereo.
public final class OpusStereoDecoder {
    // A custom callback status means more live packets may arrive. Returning
    // noErr with zero packets would permanently finish the converter's stream.
    // https://developer.apple.com/documentation/audiotoolbox/audioconvertercomplexinputdataproc
    private static let needsMoreInput: OSStatus = 1
    private var converter: AudioConverterRef?
    public init(sampleRate: UInt32 = 48000, channels: UInt32 = 2) throws {
        guard sampleRate == 48000, channels == 2 else { throw AudioDecoderError.unsupportedConfiguration }
        var source = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let status = AudioConverterNew(&source, &output, &converter)
        guard status == noErr else { throw AudioDecoderError.status(status) }
    }
    deinit { if let converter { AudioConverterDispose(converter) } }
    public func decode(_ packet: Data) throws -> [Float] {
        guard !packet.isEmpty, packet.count <= 65535, let converter else { throw AudioDecoderError.malformedPacket }
        var samples = [Float](repeating: 0, count: 5760 * 2)
        var frames: UInt32 = 5760
        let status = packet.withUnsafeBytes { bytes in
            let input = PacketInput(pointer: bytes.baseAddress!, length: bytes.count)
            return samples.withUnsafeMutableBytes { output in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(output.count), mData: output.baseAddress!))
                return AudioConverterFillComplexBuffer(converter, { _, count, buffers, descriptions, context in
                    guard let context else { return kAudio_ParamError }
                    let input = Unmanaged<PacketInput>.fromOpaque(context).takeUnretainedValue()
                    if input.used {
                        count.pointee = 0
                        buffers.pointee.mBuffers.mData = nil; buffers.pointee.mBuffers.mDataByteSize = 0
                        descriptions?.pointee = nil
                        return OpusStereoDecoder.needsMoreInput
                    }
                    input.used = true; count.pointee = 1
                    buffers.pointee.mNumberBuffers = 1
                    buffers.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(input.length),
                        mData: UnsafeMutableRawPointer(mutating: input.pointer))
                    descriptions?.pointee = input.description
                    return noErr
                }, Unmanaged.passUnretained(input).toOpaque(), &frames, &buffers, nil)
            }
        }
        guard status == noErr || status == Self.needsMoreInput, frames <= 5760 else { throw AudioDecoderError.status(status) }
        return Array(samples.prefix(Int(frames) * 2))
    }
    private final class PacketInput {
        let pointer: UnsafeRawPointer
        let length: Int
        var used = false
        let description: UnsafeMutablePointer<AudioStreamPacketDescription>
        init(pointer: UnsafeRawPointer, length: Int) {
            self.pointer = pointer; self.length = length
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(length)))
        }
        deinit { description.deinitialize(count: 1); description.deallocate() }
    }
}
