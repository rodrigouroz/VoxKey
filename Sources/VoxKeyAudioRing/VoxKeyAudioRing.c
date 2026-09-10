#include "VoxKeyAudioRing.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct VKAudioRing {
    float *storage;
    size_t capacity;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic bool overflowed;
};

VKAudioRing *vk_audio_ring_create(size_t capacity) {
    if (capacity == 0) {
        return NULL;
    }

    VKAudioRing *ring = calloc(1, sizeof(VKAudioRing));
    if (ring == NULL) {
        return NULL;
    }

    ring->storage = calloc(capacity, sizeof(float));
    if (ring->storage == NULL) {
        free(ring);
        return NULL;
    }

    ring->capacity = capacity;
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->overflowed, false);
    return ring;
}

void vk_audio_ring_destroy(VKAudioRing *ring) {
    if (ring == NULL) {
        return;
    }
    free(ring->storage);
    free(ring);
}

bool vk_audio_ring_write(VKAudioRing *ring, const float *samples, size_t count) {
    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    const size_t available_capacity = ring->capacity - (size_t)(write_index - read_index);

    if (count > available_capacity) {
        atomic_store_explicit(&ring->overflowed, true, memory_order_release);
        return false;
    }

    const size_t offset = (size_t)(write_index % ring->capacity);
    const size_t first_count = count < (ring->capacity - offset) ? count : (ring->capacity - offset);
    memcpy(ring->storage + offset, samples, first_count * sizeof(float));
    if (first_count < count) {
        memcpy(ring->storage, samples + first_count, (count - first_count) * sizeof(float));
    }

    atomic_store_explicit(&ring->write_index, write_index + count, memory_order_release);
    return true;
}

size_t vk_audio_ring_read(VKAudioRing *ring, float *destination, size_t maximum_count) {
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    const size_t available = (size_t)(write_index - read_index);
    const size_t count = available < maximum_count ? available : maximum_count;
    const size_t offset = (size_t)(read_index % ring->capacity);
    const size_t first_count = count < (ring->capacity - offset) ? count : (ring->capacity - offset);

    memcpy(destination, ring->storage + offset, first_count * sizeof(float));
    if (first_count < count) {
        memcpy(destination + first_count, ring->storage, (count - first_count) * sizeof(float));
    }

    atomic_store_explicit(&ring->read_index, read_index + count, memory_order_release);
    return count;
}

size_t vk_audio_ring_available(const VKAudioRing *ring) {
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    return (size_t)(write_index - read_index);
}

bool vk_audio_ring_overflowed(const VKAudioRing *ring) {
    return atomic_load_explicit(&ring->overflowed, memory_order_acquire);
}
