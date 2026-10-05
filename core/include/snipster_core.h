// C interface to the Rust pixel core (../src/lib.rs). Keep the two in sync.
//
// Every image is premultiplied BGRA, 8 bits per channel, `stride` bytes per row.

#ifndef SNIPSTER_CORE_H
#define SNIPSTER_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A heap buffer owned by the core. Release it with `snip_buffer_free`.
typedef struct SnipBuffer {
    uint8_t *ptr;
    size_t len;
    size_t cap;
} SnipBuffer;

typedef struct SnipRect {
    size_t x;
    size_t y;
    size_t w;
    size_t h;
} SnipRect;

typedef struct SnipStitcher SnipStitcher;

/// Write RGB and drop alpha. Use for anything captured straight off a display.
#define SNIP_PNG_OPAQUE (1u << 0)
/// Choose the best row filter per scanline: smaller files, slightly slower.
#define SNIP_PNG_ADAPTIVE (1u << 1)

#define SNIP_STITCH_NO_MATCH (-1)
#define SNIP_STITCH_FULL (-2)

/// Encodes `crop` of the image as a PNG, compressing on all cores.
/// `level` is the zlib level (1-9), `dpi` goes into pHYs (0 to omit).
/// Returns an empty buffer (len 0) if the input is invalid or the crop is empty.
SnipBuffer snip_encode_png(const uint8_t *bgra, size_t width, size_t height, size_t stride,
                           SnipRect crop, uint32_t flags, uint32_t level, uint32_t dpi);

void snip_buffer_free(SnipBuffer buffer);

/// Mosaics `region` in place with `block`-pixel cells.
void snip_pixelate(uint8_t *bgra, size_t width, size_t height, size_t stride, SnipRect region, size_t block);

/// Blurs `region` in place. `radius` is the Gaussian sigma in pixels.
void snip_blur(uint8_t *bgra, size_t width, size_t height, size_t stride, SnipRect region, size_t radius);

/// Stitcher for scrolling captures; every frame must be `width` x `height`.
/// The rightmost `ignore_right` columns are left out of matching.
SnipStitcher *snip_stitcher_new(size_t width, size_t height, size_t ignore_right);

/// Returns the rows appended (0 if the frame showed nothing new) or a
/// negative SNIP_STITCH_* code if the frame was ignored.
int64_t snip_stitcher_push(SnipStitcher *stitcher, const uint8_t *bgra, size_t stride);

/// Height of the image `snip_stitcher_finish` would return now.
size_t snip_stitcher_height(const SnipStitcher *stitcher);

/// Consumes the stitcher. The result is tightly packed (stride = width * 4).
SnipBuffer snip_stitcher_finish(SnipStitcher *stitcher, size_t *out_height);

void snip_stitcher_free(SnipStitcher *stitcher);

#ifdef __cplusplus
}
#endif

#endif
