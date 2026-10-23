import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ProviderConnectionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(width: 330, height: 76)
        }
        .buttonStyle(.bordered)
    }
}

struct ProviderSettingsHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

struct ProviderQRCodeSignInView: View {
    let title: String
    let systemImage: String
    let tint: Color
    let qrValue: String
    let instruction: String
    var code: String? = nil
    var status: String? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: systemImage)
                .font(.system(size: 58, weight: .bold))
                .foregroundStyle(tint)
            Text(title).font(.title.weight(.semibold))
            if let image = ProviderQRCode.image(from: qrValue) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
            Text(instruction)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)
            if let code, !code.isEmpty {
                Text(formatted(code))
                    .font(.system(size: 58, weight: .bold, design: .monospaced))
                    .tracking(7)
            }
            if let status {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(status).foregroundStyle(.secondary)
                }
            }
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(AppActionButtonStyle(tone: .secondary, minWidth: 150))
            }
        }
        .padding(60)
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4)) — \(code.suffix(4))"
    }
}

struct ProviderConnectionProgressView: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: systemImage).font(.system(size: 58, weight: .bold)).foregroundStyle(tint)
            ProgressView().scaleEffect(1.8)
            Text(title).font(.title2)
        }
        .padding(60)
    }
}

enum ProviderQRCode {
    static func image(from string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
