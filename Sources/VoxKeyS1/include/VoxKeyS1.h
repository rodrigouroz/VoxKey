#ifndef VOXKEY_S1_H
#define VOXKEY_S1_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct vk_s1 vk_s1;
enum { VK_S1_OK = 0, VK_S1_CANCELLED = 1, VK_S1_TOO_LONG = 2, VK_S1_FAILED = 3, VK_S1_INCOMPLETE = 4 };
vk_s1 * vk_s1_create(void);
int vk_s1_load(vk_s1 *, const char * model_path);
int vk_s1_generate(vk_s1 *, const char * prompt, int lookup_enabled);
void vk_s1_cancel(vk_s1 *); // Thread-safe and permanent for this handle.
void vk_s1_destroy(vk_s1 *); // Only after queued load/generation has returned.
const char * vk_s1_text(const vk_s1 *);
const int32_t * vk_s1_tokens(const vk_s1 *);
size_t vk_s1_token_count(const vk_s1 *);
uint64_t vk_s1_proposed(const vk_s1 *);
uint64_t vk_s1_accepted(const vk_s1 *);
#ifdef __cplusplus
}
#endif
#endif
