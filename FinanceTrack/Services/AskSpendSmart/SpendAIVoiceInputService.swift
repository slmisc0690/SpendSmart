import Foundation
import Observation
import Speech
import AVFoundation

/// SPENDAI VOICE INPUT — captures a spoken question via Apple's on-device Speech framework and
/// auto-submits it 3 seconds after the user stops talking (per Scott's explicit spec: enough time
/// to think mid-sentence without a premature cutoff, but no manual "done" tap required). Every
/// state change happens on the main actor since this only ever drives SwiftUI.
///
/// PERMISSION FAILURE IS NEVER FATAL — a denied/restricted microphone or speech-recognition
/// permission (or an unsupported locale) makes `startListening` a silent no-op that reports
/// `.denied`; the caller (`AskSpendSmartView`) falls back to the existing keyboard input, exactly
/// as it already behaves for every user before this feature existed. No retry loop, no forced
/// re-prompt — iOS itself only ever asks once per install.
@Observable
@MainActor
final class SpendAIVoiceInputService {
    enum PermissionState {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var permissionState: PermissionState = .notDetermined
    private(set) var isListening = false
    private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var onAutoSubmit: ((String) -> Void)?

    /// Requests BOTH permissions this feature needs (speech recognition + microphone) exactly
    /// once — iOS itself no-ops a second system prompt if the user already answered, so repeated
    /// calls are safe. Returns the resolved `PermissionState` for the caller to act on immediately,
    /// as well as updating `permissionState` for later reads.
    func requestPermissionIfNeeded() async -> PermissionState {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            permissionState = .denied
            return .denied
        }
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        permissionState = micGranted ? .authorized : .denied
        return permissionState
    }

    /// Current permission state WITHOUT prompting — used to decide, on every SpendAI open, whether
    /// to go straight to listening (already authorized), ask once (never asked before), or skip
    /// voice entirely and land on the keyboard (previously denied — iOS won't re-prompt, and this
    /// service must never pretend otherwise).
    func currentPermissionState() -> PermissionState {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined { return .notDetermined }
        guard speechStatus == .authorized else { return .denied }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .granted: return .authorized
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// Starts capturing audio and live-transcribing it. `onAutoSubmit` fires exactly once, 3
    /// seconds after the transcript last changed (and only if it's non-empty) — never on a timer
    /// that ignores ongoing speech, so thinking mid-question never truncates it early. A no-op if
    /// permission isn't `.authorized` or the recognizer is unavailable (e.g. no network the very
    /// first time this locale's on-device model needs downloading, or Recognition is
    /// device-disabled) — `permissionState` is left as `.denied` in that case so the caller falls
    /// back to the keyboard rather than showing a dead "listening" UI.
    func startListening(onAutoSubmit: @escaping (String) -> Void) {
        guard permissionState == .authorized || currentPermissionState() == .authorized else { return }
        guard let recognizer, recognizer.isAvailable else {
            permissionState = .denied
            return
        }
        self.onAutoSubmit = onAutoSubmit
        transcript = ""

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            permissionState = .denied
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device only — never uploads audio to Apple's servers, matching this app's own
        // never-send-financial-data-anywhere-unnecessary posture, even though a spoken question's
        // content isn't itself sensitive account data.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            permissionState = .denied
            recognitionRequest = nil
            return
        }
        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                }
                if error != nil || result?.isFinal == true {
                    self.stopListening()
                }
            }
        }
    }

    /// Restarted on every new transcript delta — fires `onAutoSubmit` only if 3 full seconds pass
    /// with no further speech AND there's actually something to submit, never on an empty
    /// transcript (a user who opens SpendAI and says nothing is never auto-submitted a blank
    /// question).
    private func resetSilenceTimer() {
        silenceTask?.cancel()
        let capturedTranscript = transcript
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let finalText = capturedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else { return }
            let submit = self.onAutoSubmit
            self.stopListening()
            submit?(finalText)
        }
    }

    /// Tears down the audio engine/recognition task — safe to call multiple times (a `.isFinal`
    /// result, an error, an explicit "Keyboard" tap, and view disappearance can all reach this).
    func stopListening() {
        silenceTask?.cancel()
        silenceTask = nil
        guard isListening || audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
