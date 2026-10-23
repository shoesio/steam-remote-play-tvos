import CoreMedia
import Foundation
import Metal
import OSLog

/// Screen regions are normalized, keeping sampling independent of physical lights.
/// V1 uses the full screen; future mid-room lights can add left/right rectangles.
private struct AmbientZone {
    let id: String
    let rect: SIMD4<Float>
    let accessoryName: () -> String
}

private struct AmbientSample {
    let hsv: SIMD3<Double>
    let meanBrightness: Double
    let whiteRatio: Double
    let blackRatio: Double
}

private enum AmbientScreenMode: String {
    case colour, white, black
}

@objc final class AmbientLightingController: NSObject {
    @objc static let shared = AmbientLightingController()

    private let logger = Logger(subsystem: "SteamSolarflare", category: "AmbientLighting")
    private let analysisQueue = DispatchQueue(label: "com.steamsolarflare.ambient-analysis", qos: .utility)
    private var pipeline: MTLRenderPipelineState?
    private var pipelineDevice: ObjectIdentifier?
    private var sampleTexture: MTLTexture?
    private var lastSampleTime: CFTimeInterval = 0
    private var smoothedHSV: SIMD3<Double>?
    private var screenMode: AmbientScreenMode = .colour
    private var pendingScreenMode: AmbientScreenMode?
    private var pendingScreenModeCount = 0
    private var lastOutputBrightness: Double?
    private var sampleInFlight = false
    private var writeInFlight = false
    private var sessionGeneration: UInt64 = 0
    private let zones = [AmbientZone(id: "behindTV", rect: SIMD4(0, 0, 1, 1), accessoryName: { SteamTVSettings.ambientAccessoryName })]

    @objc func restoreOriginalLightState() {
        // Invalidate GPU samples whose completion handlers have not fired yet,
        // otherwise a late ambient write can overwrite the restored state.
        sessionGeneration &+= 1
        smoothedHSV = nil
        screenMode = .colour
        pendingScreenMode = nil
        pendingScreenModeCount = 0
        lastOutputBrightness = nil
        lastSampleTime = 0
        Task { @MainActor in
            await HomeKitPowerOutletStore.shared.restoreAmbientLight()
        }
    }

    /// Adds the tiny colour sample to the renderer's existing presentation command
    /// buffer. Keeping this work in the same submission avoids an extra GPU commit
    /// on the latency-critical path for every ambient-light update.
    @objc(encodeWithLumaTexture:cbTexture:crTexture:commandBuffer:)
    func encode(lumaTexture: MTLTexture, cbTexture: MTLTexture, crTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard SteamTVSettings.ambientLightingEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastSampleTime >= 1.0 / SteamTVSettings.ambientUpdateRate,
              !sampleInFlight, !writeInFlight else { return }
        let generation = sessionGeneration
        lastSampleTime = now
        guard prepare(device: lumaTexture.device), let pipeline, let output = sampleTexture else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        sampleInFlight = true
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(cbTexture, index: 1)
        encoder.setFragmentTexture(crTexture, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [weak self] completed in
            self?.analysisQueue.async {
                guard let self else { return }
                self.sampleInFlight = false
                guard generation == self.sessionGeneration else { return }
                guard completed.status == .completed else {
                    UserDefaults.standard.set("GPU sample failed status=\(completed.status.rawValue) error=\(completed.error?.localizedDescription ?? "unknown")", forKey: "steam.ambientLastResult")
                    return
                }
                var pixels = [UInt8](repeating: 0, count: 16 * 9 * 4)
                output.getBytes(&pixels, bytesPerRow: 16 * 4, from: MTLRegionMake2D(0, 0, 16, 9), mipmapLevel: 0)
                pixels.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    self.consume(bytes: base, count: 16 * 9)
                }
            }
        }
    }

    private func prepare(device: MTLDevice) -> Bool {
        let identity = ObjectIdentifier(device)
        if pipeline != nil, pipelineDevice == identity { return true }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; float2 uv; };
        vertex VOut vertexMain(uint vid [[vertex_id]]) {
          const float2 p[4] = { {-1,-1}, {-1,1}, {1,-1}, {1,1} };
          const float2 t[4] = { {0,1}, {0,0}, {1,1}, {1,0} };
          VOut o; o.position=float4(p[vid],0,1); o.uv=t[vid]; return o;
        }
        fragment float4 sampleFragment(VOut in [[stage_in]], texture2d<float, access::sample> yTex [[texture(0)]], texture2d<float, access::sample> cbTex [[texture(1)]], texture2d<float, access::sample> crTex [[texture(2)]]) {
          constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
          float y=(yTex.sample(s,in.uv).r-16.0/255.0)*(255.0/219.0);
          float cb=(cbTex.sample(s,in.uv).r-0.5)*(255.0/224.0), cr=(crTex.sample(s,in.uv).r-0.5)*(255.0/224.0);
          float3 rgb=clamp(float3(y+1.5748*cr,y-0.187324*cb-0.468124*cr,y+1.8556*cb),0.0,1.0);
          return float4(rgb,1.0);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "sampleFragment")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 9, mipmapped: false)
            textureDescriptor.storageMode = .shared
            textureDescriptor.usage = [.renderTarget]
            sampleTexture = device.makeTexture(descriptor: textureDescriptor)
            pipelineDevice = identity
            return sampleTexture != nil
        } catch {
            logger.error("Could not prepare ambient sampler: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func consume(bytes: UnsafePointer<UInt8>, count: Int) {
        guard let zone = zones.first, let candidate = representativeColor(bytes: bytes, count: count, zone: zone) else { return }
        apply(candidate, to: zone)
    }

    private func representativeColor(bytes: UnsafePointer<UInt8>, count: Int, zone: AmbientZone) -> AmbientSample? {
        // Saturation-weighted circular hue mean avoids the grey/brown result of RGB averaging.
        var x = 0.0, y = 0.0, saturationTotal = 0.0, brightnessTotal = 0.0, weightTotal = 0.0
        var totalBrightness = 0.0, whitePixels = 0, blackPixels = 0, sampledPixels = 0
        for index in 0..<count {
            let px = Float(index % 16) / 16, py = Float(index / 16) / 9
            guard px >= zone.rect.x, py >= zone.rect.y,
                  px < zone.rect.x + zone.rect.z, py < zone.rect.y + zone.rect.w else { continue }
            let r = Double(bytes[index * 4]) / 255, g = Double(bytes[index * 4 + 1]) / 255, b = Double(bytes[index * 4 + 2]) / 255
            let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
            let saturation = maxV == 0 ? 0 : delta / maxV
            sampledPixels += 1
            totalBrightness += maxV
            if maxV <= 0.10 { blackPixels += 1 }
            if maxV >= 0.65, saturation <= 0.18 { whitePixels += 1 }
            guard maxV >= 0.08, saturation >= 0.12 else { continue }
            let hue: Double
            if delta == 0 { hue = 0 }
            else if maxV == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) / 6 }
            else if maxV == g { hue = ((b - r) / delta + 2) / 6 }
            else { hue = ((r - g) / delta + 4) / 6 }
            let normalizedHue = hue < 0 ? hue + 1 : hue
            let weight = saturation * sqrt(maxV)
            x += cos(normalizedHue * 2 * .pi) * weight; y += sin(normalizedHue * 2 * .pi) * weight
            saturationTotal += saturation * weight; brightnessTotal += maxV * weight; weightTotal += weight
        }
        guard sampledPixels > 0 else { return nil }
        var hue = weightTotal > 0.2 ? atan2(y, x) / (2 * .pi) : (smoothedHSV?.x ?? 0)
        if hue < 0 { hue += 1 }
        let hsv = SIMD3(
            hue,
            weightTotal > 0.2 ? saturationTotal / weightTotal : 0,
            weightTotal > 0.2 ? brightnessTotal / weightTotal : totalBrightness / Double(sampledPixels)
        )
        return AmbientSample(
            hsv: hsv,
            meanBrightness: totalBrightness / Double(sampledPixels),
            whiteRatio: Double(whitePixels) / Double(sampledPixels),
            blackRatio: Double(blackPixels) / Double(sampledPixels)
        )
    }

    private func apply(_ sample: AmbientSample, to zone: AmbientZone) {
        let candidate = sample.hsv
        let smoothing = SteamTVSettings.ambientSmoothing
        if let old = smoothedHSV {
            var delta = candidate.x - old.x
            if delta > 0.5 { delta -= 1 }; if delta < -0.5 { delta += 1 }
            smoothedHSV = SIMD3((old.x + delta * (1 - smoothing) + 1).truncatingRemainder(dividingBy: 1), old.y * smoothing + candidate.y * (1 - smoothing), old.z * smoothing + candidate.z * (1 - smoothing))
        } else { smoothedHSV = candidate }
        guard let hsv = smoothedHSV else { return }

        let detectedMode: AmbientScreenMode
        if sample.meanBrightness <= 0.10 || sample.blackRatio >= 0.80 {
            detectedMode = .black
        } else if sample.meanBrightness >= 0.55, sample.whiteRatio >= 0.65 {
            detectedMode = .white
        } else {
            detectedMode = .colour
        }
        if detectedMode == screenMode {
            pendingScreenMode = nil
            pendingScreenModeCount = 0
        } else if pendingScreenMode == detectedMode {
            pendingScreenModeCount += 1
            if pendingScreenModeCount >= 2 {
                screenMode = detectedMode
                pendingScreenMode = nil
                pendingScreenModeCount = 0
            }
        } else {
            pendingScreenMode = detectedMode
            pendingScreenModeCount = 1
        }

        let outputSaturation: Double
        let outputBrightness: Double
        switch screenMode {
        case .white:
            outputSaturation = 0
            outputBrightness = 100
        case .black:
            outputSaturation = 0
            outputBrightness = 50
        case .colour:
            outputSaturation = SteamTVSettings.ambientAlwaysSaturated
                ? 100
                : min(100, max(75, hsv.y * 100))
            outputBrightness = 100
        }
        let shouldUpdateBrightness = lastOutputBrightness == nil || abs((lastOutputBrightness ?? 0) - outputBrightness) >= 2
        lastOutputBrightness = outputBrightness
        UserDefaults.standard.set(
            String(format: "sample mode=%@ hue=%.1f saturation=%.1f brightness=%.1f white=%.2f black=%.2f", screenMode.rawValue, hsv.x * 360, outputSaturation, outputBrightness, sample.whiteRatio, sample.blackRatio),
            forKey: "steam.ambientLastSample"
        )
        writeInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.analysisQueue.async { self?.writeInFlight = false } }
            do {
                // Ambient mode deliberately emits one vivid colour per update.
                // Brightness is fixed; saturation is strengthened without crushing
                // already-colourful scenes beyond the HomeKit range.
                try await HomeKitPowerOutletStore.shared.setLight(
                    named: zone.accessoryName(),
                    hue: hsv.x * 360,
                    saturation: outputSaturation,
                    brightness: outputBrightness,
                    updateBrightness: shouldUpdateBrightness
                )
                UserDefaults.standard.set(
                    "success target=\(zone.accessoryName()) mode=\(self?.screenMode.rawValue ?? "unknown") hue=\(Int(hsv.x * 360)) saturation=\(Int(outputSaturation)) brightness=\(Int(outputBrightness))",
                    forKey: "steam.ambientLastResult"
                )
            } catch {
                self?.logger.error("Ambient light update failed for ‘\(zone.accessoryName(), privacy: .public)’: \(error.localizedDescription, privacy: .public)")
                print("[AmbientLighting] update failed target=\(zone.accessoryName()) error=\(error.localizedDescription)")
                UserDefaults.standard.set(
                    "failed target=\(zone.accessoryName()) error=\(error.localizedDescription)",
                    forKey: "steam.ambientLastResult"
                )
            }
        }
    }
}
