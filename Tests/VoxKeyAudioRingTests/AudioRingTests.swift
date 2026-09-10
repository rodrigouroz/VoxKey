import Testing
import VoxKeyAudioRing

@Test func preservesOrderAcrossWraparound() throws {
    let ring = try #require(vk_audio_ring_create(5))
    defer { vk_audio_ring_destroy(ring) }

    let first: [Float] = [1, 2, 3, 4]
    #expect(first.withUnsafeBufferPointer { vk_audio_ring_write(ring, $0.baseAddress!, $0.count) })

    var partial = Array(repeating: Float.zero, count: 3)
    let partialCount = partial.withUnsafeMutableBufferPointer {
        vk_audio_ring_read(ring, $0.baseAddress!, $0.count)
    }
    #expect(partialCount == 3)
    #expect(partial == [1, 2, 3])

    let second: [Float] = [5, 6, 7, 8]
    #expect(second.withUnsafeBufferPointer { vk_audio_ring_write(ring, $0.baseAddress!, $0.count) })

    var remainder = Array(repeating: Float.zero, count: 5)
    let remainderCount = remainder.withUnsafeMutableBufferPointer {
        vk_audio_ring_read(ring, $0.baseAddress!, $0.count)
    }
    #expect(remainderCount == 5)
    #expect(remainder == [4, 5, 6, 7, 8])
}

@Test func rejectsOverflowWithoutDiscardingBufferedAudio() throws {
    let ring = try #require(vk_audio_ring_create(3))
    defer { vk_audio_ring_destroy(ring) }

    let accepted: [Float] = [1, 2, 3]
    #expect(accepted.withUnsafeBufferPointer { vk_audio_ring_write(ring, $0.baseAddress!, $0.count) })
    let rejected: [Float] = [4]
    #expect(!rejected.withUnsafeBufferPointer { vk_audio_ring_write(ring, $0.baseAddress!, $0.count) })
    #expect(vk_audio_ring_overflowed(ring))
    #expect(vk_audio_ring_available(ring) == 3)

    var output = Array(repeating: Float.zero, count: 3)
    _ = output.withUnsafeMutableBufferPointer {
        vk_audio_ring_read(ring, $0.baseAddress!, $0.count)
    }
    #expect(output == accepted)
}
