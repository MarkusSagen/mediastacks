// Cover thumbnail resizer.
//
// Wraps stb_image (decode), stb_image_resize2 (downscale), and
// stb_image_write (encode JPEG). Exported as a single C entrypoint
// so Zig can call it without dealing with stb's macro contracts.
//
// Aim: drop-in for `cover.extract`'s output. Take the raw bytes
// (typically 600x900 JPEG, ~200 KB), produce a 320px-wide JPEG
// (~10-20 KB) that the gallery can paint instantly with a small
// decoded bitmap footprint.

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_IMPLEMENTATION

// Silence warnings from stb's own code. We don't care about
// unreachable paths, sign comparisons, etc. — the libs are battle-
// tested.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wsign-compare"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"

#include "../stb/stb_image.h"
#include "../stb/stb_image_write.h"
#include "../stb/stb_image_resize2.h"

#pragma GCC diagnostic pop

#include <stdlib.h>
#include <string.h>

// Output collector — stb_image_write streams encoded bytes through
// `stbi_write_func`, so we accumulate into a growable buffer.
typedef struct {
    unsigned char *data;
    size_t len;
    size_t cap;
    int failed;
} OutBuf;

static void out_write(void *ctx, void *data, int size) {
    OutBuf *o = (OutBuf *)ctx;
    if (size <= 0) return;
    if (o->failed) return;
    size_t need = o->len + (size_t)size;
    if (need > o->cap) {
        size_t new_cap = o->cap * 2;
        if (new_cap < need) new_cap = need;
        if (new_cap < 1024) new_cap = 1024;
        unsigned char *p = (unsigned char *)realloc(o->data, new_cap);
        if (!p) { o->failed = 1; return; } // OOM: mark corrupt so the caller discards it
        o->data = p;
        o->cap = new_cap;
    }
    memcpy(o->data + o->len, data, (size_t)size);
    o->len += (size_t)size;
}

// Resize `input` (encoded image bytes — JPEG/PNG/etc accepted by
// stbi_load_from_memory) to a width-capped JPEG. If the source is
// already narrower than `max_width`, returns a copy of the original
// re-encoded as JPEG (lossy, but consistent with the rest of the
// cache). Returns NULL on any failure and writes 0 to `out_len`.
//
// Caller must free the returned buffer with `free()`.
unsigned char *booktool_cover_resize(
    const unsigned char *input,
    size_t input_len,
    int max_width,
    int jpeg_quality,
    size_t *out_len
) {
    *out_len = 0;
    if (!input || input_len == 0 || max_width <= 0) return NULL;

    int w = 0, h = 0, channels = 0;
    // Force 3 channels — JPEG can't encode alpha and we get
    // deterministic stride math.
    unsigned char *pixels = stbi_load_from_memory(
        input, (int)input_len, &w, &h, &channels, 3
    );
    if (!pixels) return NULL;

    // Already smaller? Re-encode as JPEG at the requested quality
    // without resizing so cache writes are format-uniform.
    int dst_w, dst_h;
    unsigned char *dst_pixels = NULL;
    int free_dst = 0;
    if (w <= max_width) {
        dst_w = w;
        dst_h = h;
        dst_pixels = pixels;
    } else {
        dst_w = max_width;
        // Preserve aspect ratio. Round to avoid 0-height for tiny
        // edge cases (1px-wide covers don't exist, but defensive).
        dst_h = (int)((long long)h * (long long)max_width / (long long)w);
        if (dst_h < 1) dst_h = 1;

        dst_pixels = (unsigned char *)malloc((size_t)dst_w * (size_t)dst_h * 3);
        if (!dst_pixels) {
            stbi_image_free(pixels);
            return NULL;
        }
        free_dst = 1;

        // RGB resize, default sampling (mitchell-netravali-ish).
        if (!stbir_resize_uint8_linear(
            pixels, w, h, 0,
            dst_pixels, dst_w, dst_h, 0,
            STBIR_RGB
        )) {
            stbi_image_free(pixels);
            free(dst_pixels);
            return NULL;
        }
    }

    OutBuf out = {0};
    int ok = stbi_write_jpg_to_func(out_write, &out, dst_w, dst_h, 3, dst_pixels, jpeg_quality);
    if (free_dst) free(dst_pixels);
    stbi_image_free(pixels);

    if (!ok || out.failed || out.len == 0) {
        free(out.data);
        return NULL;
    }
    *out_len = out.len;
    return out.data;
}

void booktool_cover_resize_free(unsigned char *buf) {
    free(buf);
}
