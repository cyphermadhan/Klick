import SwiftUI
import AVFoundation

/// Pairing sheet. Two modes behind a terminal-style tab strip:
/// display an encryption-key QR, or scan one.
struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .display
    @State private var service = PairingService()

    enum Mode: String, CaseIterable, Identifiable {
        case display = "SHOW CODE"
        case scan = "SCAN CODE"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DT.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    header
                    modeTabs
                    Group {
                        switch mode {
                        case .display: DisplayPane(service: service)
                        case .scan:    ScanPane(service: service, dismiss: dismiss)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .preferredColorScheme(.dark)
            .toolbar(.hidden)
        }
    }

    private var header: some View {
        HStack {
            Text("PAIR · XSALSA20/P1305 KEY EXCHANGE")
                .walkieLabel(11, weight: .bold)
                .foregroundStyle(DT.text)
            Spacer()
            Button(action: { dismiss() }) {
                Text("CLOSE")
                    .walkieLabel(11)
                    .foregroundStyle(DT.warn)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { m in
                Button(action: { mode = m }) {
                    Text(m.rawValue)
                        .walkieLabel(12)
                        .foregroundStyle(mode == m ? DT.bg : DT.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == m ? DT.text : DT.panel)
                        .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Display

private struct DisplayPane: View {
    let service: PairingService
    @State private var qrImage: UIImage?
    @State private var keyFingerprint: String = ""
    @State private var errorMessage: String?
    /// True if we reused an existing key on appear. The "NEW KEY" button
    /// flips it to false and makes clear the user minted a fresh one.
    @State private var usedExistingKey: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            TerminalFrame("PUBLIC DISPLAY · DEVICE A") {
                VStack(spacing: 14) {
                    if let qrImage {
                        ZStack {
                            Rectangle().fill(Color.white)
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(14)
                        }
                        .frame(width: 240, height: 240)
                        .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                        cornerMarks
                    } else if let errorMessage {
                        Text(errorMessage)
                            .walkieLabel(11)
                            .foregroundStyle(DT.tx)
                    } else {
                        ProgressView().tint(DT.info)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        DotLeader(label: "ALGO", value: "XSALSA20")
                        DotLeader(label: "MAC", value: "POLY1305")
                        DotLeader(label: "BITS", value: "256")
                        DotLeader(label: "FPRINT", value: keyFingerprint, valueColor: DT.info)
                        DotLeader(
                            label: "STATE",
                            value: usedExistingKey ? "REUSED" : "FRESH",
                            valueColor: usedExistingKey ? DT.ok : DT.warn
                        )
                    }
                }
            }

            Text(usedExistingKey
                 ? "SHOWING YOUR ALREADY-PAIRED KEY. BOTH PHONES MUST READ THE SAME FPRINT."
                 : "NEW KEY MINTED. HAVE THE OTHER PHONE SCAN IT BEFORE TRANSMITTING.")
                .walkieCaption()
                .foregroundStyle(DT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: regenerate) {
                Text("NEW KEY · OVERWRITES EXISTING")
                    .walkieLabel(11)
                    .foregroundStyle(DT.warn)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .onAppear(perform: loadExistingOrGenerate)
    }

    private var cornerMarks: some View {
        // Hardware-y corner marks under the QR — purely decorative.
        HStack(spacing: 6) {
            ForEach(0..<28, id: \.self) { i in
                Rectangle()
                    .fill(i % 3 == 0 ? DT.info : DT.textFaint)
                    .frame(width: 4, height: 4)
            }
        }
    }

    /// On open, prefer reusing the already-stored key. Regenerating on every
    /// open was the cause of mismatched keys — if both phones opened this
    /// tab, each would overwrite the other's stored key.
    private func loadExistingOrGenerate() {
        do {
            let (key, payload) = try service.loadOrGenerateKey()
            qrImage = try service.renderQR(payload: payload, side: 220)
            keyFingerprint = PairingService.fingerprint(of: key)
            usedExistingKey = (try? service.currentKey()) == key
        } catch {
            errorMessage = "GEN FAIL: \(error.localizedDescription)"
        }
    }

    private func regenerate() {
        do {
            let (key, payload) = try service.generateAndStoreKey()
            qrImage = try service.renderQR(payload: payload, side: 220)
            keyFingerprint = PairingService.fingerprint(of: key)
            usedExistingKey = false
        } catch {
            errorMessage = "GEN FAIL: \(error.localizedDescription)"
        }
    }
}

// MARK: - Scan

private struct ScanPane: View {
    let service: PairingService
    let dismiss: DismissAction

    @State private var cameraAuthorized = false
    @State private var authDenied = false
    @State private var errorMessage: String?
    @State private var scannedKey: Data?

    var body: some View {
        Group {
            if scannedKey != nil {
                successPane
            } else if cameraAuthorized {
                scannerPane
            } else if authDenied {
                deniedPane
            } else {
                ProgressView()
                    .tint(DT.info)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await requestCameraAccess() }
            }
        }
    }

    private var scannerPane: some View {
        TerminalFrame("CAMERA · DEVICE B") {
            ZStack {
                QRScannerView(
                    onScan: handleScan,
                    onError: { errorMessage = $0 }
                )
                .clipShape(.rect)

                // Targeting reticle.
                VStack {
                    HStack {
                        cornerL(rotation: 0)
                        Spacer()
                        cornerL(rotation: 90)
                    }
                    Spacer()
                    HStack {
                        cornerL(rotation: 270)
                        Spacer()
                        cornerL(rotation: 180)
                    }
                }
                .padding(30)
                .foregroundStyle(DT.info)

                if let errorMessage {
                    VStack {
                        Spacer()
                        Text(errorMessage)
                            .walkieLabel(11)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(DT.tx)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func cornerL(rotation: Double) -> some View {
        ZStack {
            Path { p in
                p.move(to: .init(x: 0, y: 0))
                p.addLine(to: .init(x: 24, y: 0))
                p.move(to: .init(x: 0, y: 0))
                p.addLine(to: .init(x: 0, y: 24))
            }
            .stroke(DT.info, lineWidth: 2)
            .frame(width: 24, height: 24)
        }
        .frame(width: 24, height: 24)
        .rotationEffect(.degrees(rotation))
    }

    private var successPane: some View {
        TerminalFrame("PAIRING COMPLETE", accent: DT.ok) {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(DT.ok)
                Text("KEY INSTALLED")
                    .walkieLabel(16, weight: .bold, tracking: 3)
                    .foregroundStyle(DT.text)
                if let key = scannedKey {
                    // Showing the fingerprint lets the user cross-check with
                    // the displaying phone — if the hex groups don't match,
                    // pairing went sideways and they can try again.
                    VStack(spacing: 4) {
                        Text("FPRINT")
                            .walkieCaption()
                            .foregroundStyle(DT.textDim)
                        Text(PairingService.fingerprint(of: key))
                            .font(DT.mono(14, weight: .bold))
                            .foregroundStyle(DT.info)
                            .tracking(1)
                    }
                }
                Text("COMPARE FPRINT ON BOTH PHONES. IF THEY MATCH, YOU'RE GOOD.")
                    .walkieCaption()
                    .foregroundStyle(DT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button(action: { dismiss() }) {
                    Text("DONE")
                        .walkieLabel(12, weight: .bold)
                        .foregroundStyle(DT.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DT.ok)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var deniedPane: some View {
        TerminalFrame("CAMERA BLOCKED", accent: DT.warn) {
            VStack(spacing: 12) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DT.warn)
                Text("CAMERA ACCESS REQUIRED")
                    .walkieLabel(12)
                    .foregroundStyle(DT.text)
                Text("ENABLE IN SETTINGS → WALKIE.")
                    .walkieCaption()
                    .foregroundStyle(DT.textDim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func requestCameraAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            authDenied = !cameraAuthorized
        default:
            authDenied = true
        }
    }

    private func handleScan(_ payload: String) {
        do {
            let key = try service.acceptScannedPayload(payload)
            scannedKey = key
        } catch {
            errorMessage = "INVALID CODE · \(error.localizedDescription.uppercased())"
        }
    }
}
