import Foundation
import SpeakerMatchingCore

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message) (actual: \(actual), expected: \(expected))")
}

private func expectClose(_ actual: Float, _ expected: Float, accuracy: Float = 0.0001, _ message: String) {
    expect(abs(actual - expected) <= accuracy, "\(message) (actual: \(actual), expected: \(expected))")
}

private func runSourceAwareScoringChecks() {
    let config = SourceAwareScoringConfig(
        sameSourceBonus: 0.02,
        crossSourcePenalty: 0.03,
        mixedSourcePenalty: 0.01
    )

    let micSample = SourceAwareScoring.adjustedSimilarity(
        rawSimilarity: 0.58,
        candidateSource: .system,
        sampleSource: .microphone,
        config: config
    )
    let systemSample = SourceAwareScoring.adjustedSimilarity(
        rawSimilarity: 0.56,
        candidateSource: .system,
        sampleSource: .system,
        config: config
    )
    expect(systemSample > micSample, "same-source adjustment should break close ties")

    let unknown = SourceAwareScoring.adjustedSimilarity(
        rawSimilarity: 0.57,
        candidateSource: .unknown,
        sampleSource: .microphone
    )
    expectClose(unknown, 0.57, "unknown source should leave similarity unchanged")

    let mixed = SourceAwareScoring.adjustedSimilarity(
        rawSimilarity: 0.57,
        candidateSource: .mixed,
        sampleSource: .system
    )
    expectClose(mixed, 0.56, "mixed source should apply only the small mixed penalty")

    let upper = SourceAwareScoring.adjustedSimilarity(
        rawSimilarity: 0.99,
        candidateSource: .microphone,
        sampleSource: .microphone
    )
    let lower = SourceAwareScoring.adjustedSimilarity(
        rawSimilarity: 0.01,
        candidateSource: .microphone,
        sampleSource: .system
    )
    expectClose(upper, 1.0, "adjusted similarity should clamp upper bound")
    expectClose(lower, 0.0, "adjusted similarity should clamp lower bound")
}

private func runSourceClassifierChecks() {
    expectEqual(
        AudioSourceEnergyClassifier.classify(
            microphoneEnergy: 0.01,
            systemEnergy: 0.001,
            dominanceRatio: 1.6
        ),
        .microphone,
        "dominant mic energy should classify as microphone"
    )

    expectEqual(
        AudioSourceEnergyClassifier.classify(
            microphoneEnergy: 0.001,
            systemEnergy: 0.01,
            dominanceRatio: 1.6
        ),
        .system,
        "dominant system energy should classify as system"
    )

    expectEqual(
        AudioSourceEnergyClassifier.classify(
            microphoneEnergy: 0.01,
            systemEnergy: 0.009,
            dominanceRatio: 1.6
        ),
        .mixed,
        "similar mic/system energies should classify as mixed"
    )

    expectEqual(
        AudioSourceEnergyClassifier.classify(
            microphoneEnergy: nil,
            systemEnergy: nil
        ),
        .unknown,
        "missing stem data should classify as unknown"
    )

    let final = URL(fileURLWithPath: "/tmp/20260415_120000.wav")
    let stems = AudioSourceStemURLs.expectedSiblings(for: final)
    expectEqual(stems.microphoneURL.lastPathComponent, "20260415_120000.mic.wav", "mic stem name")
    expectEqual(stems.systemURL.lastPathComponent, "20260415_120000.sys.wav", "system stem name")
}

runSourceAwareScoringChecks()
runSourceClassifierChecks()
print("SpeakerMatchingCore checks passed")
