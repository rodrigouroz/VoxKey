#ifndef VOXKEY_AUDIO_RING_H
#define VOXKEY_AUDIO_RING_H

#include <stdbool.h>
#include <stddef.h>

typedef struct VKAudioRing VKAudioRing;

VKAudioRing * _Nullable vk_audio_ring_create(size_t capacity);
void vk_audio_ring_destroy(VKAudioRing * _Nullable ring);
bool vk_audio_ring_write(VKAudioRing * _Nonnull ring, const float * _Nonnull samples, size_t count);
size_t vk_audio_ring_read(VKAudioRing * _Nonnull ring, float * _Nonnull destination, size_t maximum_count);
size_t vk_audio_ring_available(const VKAudioRing * _Nonnull ring);
bool vk_audio_ring_overflowed(const VKAudioRing * _Nonnull ring);

#endif
