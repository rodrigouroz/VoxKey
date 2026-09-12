#include "VoxKeyS1.h"
#include <llama/llama.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

struct vk_s1 {
    std::atomic<bool> cancelled{false};
    std::chrono::steady_clock::time_point deadline;
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    llama_sampler * sampler = nullptr;
    std::vector<llama_token> output;
    std::string text;
    uint64_t proposed = 0, accepted = 0;
    bool interrupted() const { return cancelled.load() || std::chrono::steady_clock::now() >= deadline; }
    ~vk_s1() {
        if (sampler) llama_sampler_free(sampler);
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
};

static bool abort_generation(void * data) { return static_cast<vk_s1 *>(data)->interrupted(); }
static bool load_progress(float, void * data) { return !abort_generation(data); }

// Adapted from common_ngram_simple_draft, llama.cpp 5266f24da (MIT).
// Preserve its backward search bounds and minimum copy length exactly.
static std::vector<llama_token> draft(const std::vector<llama_token> & history, llama_token sampled) {
    constexpr size_t n = 3, m = 16;
    const size_t length = history.size();
    if (length <= n + m + 1) return {};
    const llama_token pattern[] = {history[length - 2], history[length - 1], sampled};
    for (size_t position = length - n - 1; position > 0; --position) {
        if (!std::equal(pattern, pattern + n, history.begin() + position)) continue;
        const size_t count = std::min(m, length - (position + n));
        if (count < n) return {};
        return {history.begin() + position + n, history.begin() + position + n + count};
    }
    return {};
}

static int decode(vk_s1 * state, const std::vector<llama_token> & tokens, size_t offset, size_t count,
                  int32_t position, bool all_logits) {
    if (state->interrupted()) return VK_S1_CANCELLED;
    llama_batch batch = llama_batch_init(static_cast<int32_t>(count), 0, 1);
    batch.n_tokens = static_cast<int32_t>(count);
    for (size_t i = 0; i < count; ++i) {
        batch.token[i] = tokens[offset + i];
        batch.pos[i] = position + static_cast<int32_t>(i);
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = all_logits || i == count - 1;
    }
    const int result = llama_decode(state->context, batch);
    llama_batch_free(batch);
    if (state->interrupted()) return VK_S1_CANCELLED;
    return result == 0 ? VK_S1_OK : VK_S1_FAILED;
}

extern "C" vk_s1 * vk_s1_create(void) {
    try { return new vk_s1(); } catch (...) { return nullptr; }
}
extern "C" void vk_s1_cancel(vk_s1 * state) { if (state) state->cancelled.store(true); }
extern "C" void vk_s1_destroy(vk_s1 * state) { delete state; }

extern "C" int vk_s1_load(vk_s1 * state, const char * path) {
    try {
        state->deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
        if (state->interrupted()) return VK_S1_CANCELLED;
        static std::once_flag initialized;
        std::call_once(initialized, [] {
            llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
            llama_backend_init();
        });
        auto model_params = llama_model_default_params();
        model_params.n_gpu_layers = INT_MAX;
        model_params.progress_callback = load_progress;
        model_params.progress_callback_user_data = state;
        state->model = llama_model_load_from_file(path, model_params);
        if (state->interrupted()) return VK_S1_CANCELLED;
        if (!state->model) return VK_S1_FAILED;
        char architecture[32] = {};
        llama_model_meta_val_str(state->model, "general.architecture", architecture, sizeof(architecture));
        if (std::strcmp(architecture, "qwen3") != 0) return VK_S1_FAILED;
        auto params = llama_context_default_params();
        params.n_ctx = 4096;
        params.n_batch = 512;
        params.n_ubatch = 512;
        params.n_seq_max = 1;
        params.n_threads = 4;
        params.n_threads_batch = 4;
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
        params.abort_callback = abort_generation;
        params.abort_callback_data = state;
        state->context = llama_init_from_model(state->model, params);
        if (state->interrupted()) return VK_S1_CANCELLED;
        if (!state->context) return VK_S1_FAILED;
        state->sampler = llama_sampler_init_greedy();
        return state->sampler ? VK_S1_OK : VK_S1_FAILED;
    } catch (...) { return VK_S1_FAILED; }
}

extern "C" int vk_s1_generate(vk_s1 * state, const char * prompt, int lookup_enabled) {
    if (!state || !state->context) return VK_S1_FAILED;
    // Always clear prior prompt/KV, including on cancellation or malformed output.
    struct ClearMemory {
        llama_context * context;
        ~ClearMemory() { llama_memory_clear(llama_get_memory(context), true); }
    } clear{state->context};
    try {
        state->deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        if (state->interrupted()) return VK_S1_CANCELLED;
        state->output.clear(); state->text.clear(); state->proposed = state->accepted = 0;
        llama_memory_clear(llama_get_memory(state->context), true);
        const auto * vocab = llama_model_get_vocab(state->model);
        int count = llama_tokenize(vocab, prompt, static_cast<int32_t>(std::strlen(prompt)), nullptr, 0, true, true);
        count = count < 0 ? -count : count;
        if (count < 1 || count + 1024 + 8 > 4096) return VK_S1_TOO_LONG;
        std::vector<llama_token> history(count);
        if (llama_tokenize(vocab, prompt, static_cast<int32_t>(std::strlen(prompt)), history.data(), count, true, true) != count) return VK_S1_FAILED;
        for (size_t offset = 0; offset < history.size(); offset += 512) {
            int result = decode(state, history, offset, std::min(size_t(512), history.size() - offset), static_cast<int32_t>(offset), false);
            if (result) return result;
        }
        llama_token pending = llama_sampler_sample(state->sampler, state->context, -1);
        bool eos = false;
        while (state->output.size() < 1024) {
            if (state->interrupted()) return VK_S1_CANCELLED;
            state->output.push_back(pending);
            if (llama_vocab_is_eog(vocab, pending)) { eos = true; break; }
            auto proposals = lookup_enabled ? draft(history, pending) : std::vector<llama_token>{};
            const size_t room = 1024 - state->output.size();
            if (proposals.size() > room) proposals.resize(room);
            state->proposed += proposals.size();
            std::vector<llama_token> batch{pending};
            batch.insert(batch.end(), proposals.begin(), proposals.end());
            const int32_t position = static_cast<int32_t>(history.size());
            int result = decode(state, batch, 0, batch.size(), position, true);
            if (result) return result;
            history.push_back(pending);
            size_t accepted = 0;
            pending = llama_sampler_sample(state->sampler, state->context, 0);
            while (accepted < proposals.size() && proposals[accepted] == pending) {
                state->output.push_back(pending);
                history.push_back(pending);
                ++accepted;
                if (llama_vocab_is_eog(vocab, pending)) { eos = true; break; }
                pending = llama_sampler_sample(state->sampler, state->context, static_cast<int32_t>(accepted));
            }
            state->accepted += accepted;
            if (!llama_memory_seq_rm(llama_get_memory(state->context), 0, static_cast<int32_t>(history.size()), -1)) return VK_S1_FAILED;
            if (eos) break;
        }
        if (!eos || state->output.empty() || state->output.back() != 151645) return VK_S1_INCOMPLETE;
        std::vector<char> text(32768);
        int length = llama_detokenize(vocab, state->output.data(), static_cast<int32_t>(state->output.size()), text.data(), static_cast<int32_t>(text.size()), true, false);
        if (length < 0) return VK_S1_FAILED;
        state->text.assign(text.data(), length);
        return state->interrupted() ? VK_S1_CANCELLED : VK_S1_OK;
    } catch (...) { return VK_S1_FAILED; }
}

extern "C" const char * vk_s1_text(const vk_s1 * state) { return state->text.c_str(); }
extern "C" const int32_t * vk_s1_tokens(const vk_s1 * state) { return state->output.data(); }
extern "C" size_t vk_s1_token_count(const vk_s1 * state) { return state->output.size(); }
extern "C" uint64_t vk_s1_proposed(const vk_s1 * state) { return state->proposed; }
extern "C" uint64_t vk_s1_accepted(const vk_s1 * state) { return state->accepted; }
