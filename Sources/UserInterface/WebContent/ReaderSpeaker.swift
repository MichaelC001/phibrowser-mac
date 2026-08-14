// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AVFoundation
import Foundation
import NaturalLanguage

/// Reads an article aloud with the system's speech voices.
///
/// The article arrives as the blocks the reader is showing, in reading order,
/// and each block is spoken in a voice chosen for the language of *that
/// block* rather than of the document. A page is frequently not in one
/// language — a Chinese design note quoting an English spec, a release note
/// printed twice — and one voice for the whole article reads the other half
/// in the wrong accent, or as nothing at all.
@MainActor
final class ReaderSpeaker: NSObject {

    enum State {
        case idle, speaking, paused

        /// Whether a reading is under way. Paused counts: the position is
        /// still held and the transport controls still apply.
        var isActive: Bool { self != .idle }
    }

    /// Reading speed as a multiple of the system's normal pace.
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Fired when the reading starts, stops, pauses or resumes.
    var onStateChange: ((State) -> Void)?
    /// Fired with the index of the block now being spoken, for the caller to
    /// mark in the document.
    var onPassageChange: ((Int) -> Void)?

    /// Every language this article is read in, in the order first met. The
    /// voice menu is built from this, so it offers voices for the languages
    /// on the page rather than the hundreds macOS installs.
    private(set) var spokenLanguages: [String] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var passages: [Passage] = []
    private(set) var currentIndex = 0
    /// Bumped whenever the queue is rebuilt. A cancelled utterance still
    /// reports back, and without this the callback from the queue that was
    /// just thrown away would move the highlight of the one replacing it.
    private var generation = 0
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        // Closing the tab drops its content controller, and with it this
        // surface, without anything calling `stop` on the way past. Speech
        // that survived would have no reader left to pause it from.
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Transport

    /// Starts reading `texts` from the top, replacing any reading in
    /// progress. `articleLanguage` is the document's own declared language,
    /// used for blocks too short to identify on their own.
    func start(texts: [String], articleLanguage: String?) {
        stop()
        let fallback = Self.canonical(articleLanguage)
            ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let languages = Self.languages(for: texts, fallback: fallback)
        passages = zip(texts, languages).map { Passage(text: $0, language: $1) }
        spokenLanguages = languages.reduce(into: []) { seen, language in
            if !seen.contains(language) { seen.append(language) }
        }
        guard !passages.isEmpty else { return }
        logLanguages()
        speak(from: 0)
    }

    /// Which language each part of the article was taken to be, and what will
    /// read it. The whole feature turns on that judgement, and it is the one
    /// thing a listener cannot check for themselves — a wrong call is heard
    /// as a mispronounced article, not as a detection fault.
    private func logLanguages() {
        let summary = spokenLanguages.map { language -> String in
            let blocks = passages.filter { $0.language == language }.count
            let voice = voice(for: language)?.name ?? "none installed"
            return "\(language)×\(blocks) → \(voice)"
        }
        AppLogDebug("[Reader] reading \(passages.count) blocks aloud: " +
                    summary.joined(separator: ", "))
    }

    /// True when nothing on the machine can pronounce this article. Checked
    /// before starting so the reader can say so rather than sitting silent.
    var hasUsableVoice: Bool {
        passages.contains { voice(for: $0.language) != nil }
    }

    func pause() {
        guard state == .speaking else { return }
        // `.word` rather than `.immediate`: stopping mid-word and resuming
        // repeats the half-word, which sounds like a fault.
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .speaking
    }

    func stop() {
        generation += 1
        passages = []
        spokenLanguages = []
        currentIndex = 0
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
    }

    /// Moves `delta` blocks and reads on from there. Going back from partway
    /// through a block restarts that block first, which is what "back" means
    /// while listening.
    func skip(by delta: Int) {
        guard state.isActive, !passages.isEmpty else { return }
        let target = min(max(currentIndex + delta, 0), passages.count - 1)
        speak(from: target)
    }

    // MARK: - Settings

    var speed: Double {
        get { PhiPreferences.Reader.speechSpeed }
        set {
            guard newValue != PhiPreferences.Reader.speechSpeed else { return }
            PhiPreferences.Reader.speechSpeed = newValue
            restartCurrentPassage()
        }
    }

    /// The voice chosen for a language, or nil for whichever one the system
    /// offers. Stored per language, because an article that changes language
    /// needs a choice for each.
    func voiceIdentifier(forLanguage language: String) -> String? {
        PhiPreferences.Reader.speechVoiceIdentifier(forLanguage: language)
    }

    func setVoiceIdentifier(_ identifier: String?, forLanguage language: String) {
        PhiPreferences.Reader.setSpeechVoiceIdentifier(identifier, forLanguage: language)
        voiceCache.removeValue(forKey: language)
        restartCurrentPassage()
    }

    /// A speed or voice change cannot be applied to speech already queued —
    /// an utterance carries both from the moment it is enqueued — so the
    /// block being read is begun again with the new setting. Restarting the
    /// block rather than the article is the smallest jump that can be heard
    /// to have worked.
    private func restartCurrentPassage() {
        guard state.isActive else { return }
        let wasPaused = state == .paused
        speak(from: currentIndex)
        if wasPaused { pause() }
    }

    // MARK: - Speaking

    private func speak(from index: Int) {
        generation += 1
        let generation = self.generation
        synthesizer.stopSpeaking(at: .immediate)
        currentIndex = index
        for offset in index..<passages.count {
            let passage = passages[offset]
            let utterance = ReaderUtterance(passage: passage,
                                            index: offset,
                                            generation: generation)
            utterance.voice = voice(for: passage.language)
            utterance.rate = Self.rate(forSpeed: speed)
            // A beat between blocks, so paragraphs do not run together the
            // way they would if the queue were read as one string.
            utterance.postUtteranceDelay = 0.2
            synthesizer.speak(utterance)
        }
        state = .speaking
        onPassageChange?(index)
    }

    /// Maps a speed multiple onto `AVSpeechUtterance`'s rate, whose scale is
    /// its own: 0.5 is the normal pace and 1.0 is roughly four times it, so
    /// the useful multiples live in a narrow band that a naive `0.5 × speed`
    /// would overshoot badly.
    static func rate(forSpeed speed: Double) -> Float {
        let rate = (2 + speed) / 6
        return Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                         Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    private func finished(_ utterance: ReaderUtterance) {
        guard utterance.generation == generation else { return }
        guard utterance.index == passages.count - 1 else { return }
        // The last block has been read: end the session rather than leaving
        // the transport controls sitting over a silent article.
        stop()
    }

    private func began(_ utterance: ReaderUtterance) {
        guard utterance.generation == generation else { return }
        currentIndex = utterance.index
        onPassageChange?(utterance.index)
    }

    // MARK: - Voices

    /// Every voice that can read `language`, one entry per name: macOS
    /// installs the same voice at several qualities and listing "Ting-Ting"
    /// three times asks the reader to pick between things they cannot tell
    /// apart from the menu.
    static func voices(forLanguage language: String) -> [AVSpeechSynthesisVoice] {
        var best: [String: AVSpeechSynthesisVoice] = [:]
        for voice in matches(forLanguage: language) {
            if let existing = best[voice.name],
               existing.quality.rawValue >= voice.quality.rawValue {
                continue
            }
            best[voice.name] = voice
        }
        return best.values.sorted { $0.name < $1.name }
    }

    private static func matches(forLanguage language: String) -> [AVSpeechSynthesisVoice] {
        let base = String(language.prefix { $0 != "-" })
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == base || $0.language.hasPrefix(base + "-")
        }
        // Chinese is the case where the base tag is not enough: a Simplified
        // page read by a Taiwanese voice is wrong in both pronunciation and
        // vocabulary. Narrow to the script's regions when the detector named
        // one, and only if that leaves anything installed.
        guard let regions = scriptRegions(forLanguage: language) else { return all }
        let narrowed = all.filter { voice in
            regions.contains { voice.language.hasSuffix("-" + $0) }
        }
        return narrowed.isEmpty ? all : narrowed
    }

    private static func scriptRegions(forLanguage language: String) -> [String]? {
        switch language {
        case "zh-Hans": return ["CN", "SG"]
        case "zh-Hant": return ["TW", "HK", "MO"]
        default: return nil
        }
    }

    private func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }
        let resolved = Self.resolveVoice(for: language)
        voiceCache[language] = resolved
        return resolved
    }

    private static func resolveVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let identifier = PhiPreferences.Reader.speechVoiceIdentifier(forLanguage: language),
           let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        return automaticVoice(forLanguage: language)
    }

    /// The voice to use when the reader has not chosen one: the best quality
    /// installed, preferring the region the machine is set to. Quality is
    /// worth ranking on because the voice macOS ships by default is the
    /// compact one, and it is the reason people call synthesised speech
    /// robotic.
    static func automaticVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier
        return matches(forLanguage: language).max { first, second in
            score(first, region: region) < score(second, region: region)
        }
    }

    private static func score(_ voice: AVSpeechSynthesisVoice, region: String?) -> Int {
        var score = voice.quality.rawValue * 10
        if let region, voice.language.hasSuffix("-" + region) { score += 5 }
        return score
    }

    // MARK: - Language

    /// Blocks shorter than this are not put to the detector. Language
    /// identification on a handful of characters is close to a coin toss,
    /// and a heading or a one-line caption is exactly that short.
    private static let minimumDetectableLength = 16

    /// The language to read each block in.
    ///
    /// Detection is per block: the smallest unit where it is reliable, and
    /// the unit at which a page actually changes language.
    ///
    /// A block too short to call takes the language of the next block that
    /// could be called, and only failing that the previous one. Headings are
    /// most of what is too short, and a heading belongs to the section under
    /// it — looking backwards instead announced the title of an English
    /// section in the voice of the French paragraph that had just ended.
    private static func languages(for texts: [String], fallback: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        let detected: [String?] = texts.map { text in
            guard text.count >= minimumDetectableLength else { return nil }
            recognizer.reset()
            recognizer.processString(text)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
            guard let best = hypotheses.max(by: { $0.value < $1.value }),
                  best.value >= 0.5 else {
                return nil
            }
            return best.key.rawValue
        }

        var resolved: [String] = []
        resolved.reserveCapacity(texts.count)
        var previous: String?
        for index in texts.indices {
            if let language = detected[index] {
                previous = language
                resolved.append(language)
                continue
            }
            let following = detected[(index + 1)...].compactMap { $0 }.first
            resolved.append(following ?? previous ?? fallback)
        }
        return resolved
    }

    /// Trims a document's declared language to the form the detector and the
    /// voice list both use. A page can say `en-GB`, `EN`, or `zh_CN`.
    private static func canonical(_ language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-")
        guard let base = parts.first else { return nil }
        // Keep a script subtag, which is what tells Chinese apart; drop a
        // region, which the voice ranking decides for itself.
        if parts.count > 1, parts[1].count == 4 {
            return base.lowercased() + "-" + parts[1].capitalized
        }
        return base.lowercased()
    }

    /// A block of the article and the language it will be read in.
    private struct Passage {
        let text: String
        let language: String
    }

    /// Carries its own position in the article.
    ///
    /// A side table keyed by the utterance's address would do the same until
    /// a cancelled queue is released and the replacement allocates over it,
    /// at which point a late callback reports the wrong block. The identity
    /// belongs on the object.
    private final class ReaderUtterance: AVSpeechUtterance {
        let index: Int
        let generation: Int

        init(passage: Passage, index: Int, generation: Int) {
            self.index = index
            self.generation = generation
            super.init(string: passage.text)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ReaderUtterance is never archived")
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

// Declared `nonisolated` and hopped explicitly: the callbacks make no promise
// about which queue they arrive on, and an isolated conformance would only
// paper over that.
extension ReaderSpeaker: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        guard let utterance = utterance as? ReaderUtterance else { return }
        Task { @MainActor [weak self] in self?.began(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        guard let utterance = utterance as? ReaderUtterance else { return }
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }
}
