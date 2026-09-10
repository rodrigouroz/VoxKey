import Testing
@testable import VoxKeyCore

@Test
func RMSDecibelsAndSegmentsMapSilenceAndSignal() {
    #expect(InputLevelMeter.decibelsFS([]) == -60)
    #expect(InputLevelMeter.decibelsFS([0, 0]) == -60)
    #expect(abs(InputLevelMeter.decibelsFS([0.1, -0.1]) + 20) < 0.001)
    #expect(InputLevelMeter.decibelsFS([1, -1]) == 0)
    #expect(InputLevelMeter.segments(for: InputLevelMeter.normalized(decibels: -60)) == 0)
    #expect(InputLevelMeter.segments(for: InputLevelMeter.normalized(decibels: -33)) == 3)
    #expect(InputLevelMeter.segments(for: InputLevelMeter.normalized(decibels: -6)) == 6)
    #expect(InputLevelMeter.segments(for: .nan) == 0)
}

@Test
func meterSmoothsSignalAndRemembersAudioAcrossSilence() {
    var meter = InputLevelMeter()
    meter.consume(Array(repeating: 0.1, count: 800), sampleRate: 16_000)
    let attack = meter.level
    #expect(attack > 0 && attack < InputLevelMeter.normalized(decibels: -20))
    #expect(meter.detectedAudio)
    meter.consume(Array(repeating: 0, count: 800), sampleRate: 16_000)
    #expect(meter.level > 0 && meter.level < attack)
    #expect(meter.detectedAudio)
}

@Test
func initialSilenceExplainsWhetherAnyAudioArrived() {
    #expect(InitialSilenceMessage.text(detectedAudio: false) == "No audio detected — check the microphone in Settings")
    #expect(InitialSilenceMessage.text(detectedAudio: true) == "No speech detected")
}
