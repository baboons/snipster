//! Snipster's pixel pipeline. Everything here works on premultiplied BGRA8
//! buffers, which is what ScreenCaptureKit and CoreGraphics hand the app.
//!
//! The safe Rust API lives in the modules; the `snip_*` functions below are
//! the C ABI the Swift app links against (see `include/snipster_core.h`).

pub mod effects;
pub mod png;
pub mod stitch;

use std::slice;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl Rect {
    pub const fn new(x: usize, y: usize, w: usize, h: usize) -> Self {
        Rect { x, y, w, h }
    }

    /// Intersection with a `width` x `height` image; empty if it lies outside.
    pub fn clamped(self, width: usize, height: usize) -> Rect {
        let x = self.x.min(width);
        let y = self.y.min(height);
        Rect { x, y, w: self.w.min(width - x), h: self.h.min(height - y) }
    }
}

/// A heap buffer handed to Swift. Release it with `snip_buffer_free`.
#[repr(C)]
pub struct SnipBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

impl SnipBuffer {
    fn from_vec(mut vec: Vec<u8>) -> Self {
        let buffer = SnipBuffer { ptr: vec.as_mut_ptr(), len: vec.len(), cap: vec.capacity() };
        std::mem::forget(vec);
        buffer
    }

    fn empty() -> Self {
        SnipBuffer { ptr: std::ptr::null_mut(), len: 0, cap: 0 }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SnipRect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl From<SnipRect> for Rect {
    fn from(r: SnipRect) -> Rect {
        Rect::new(r.x, r.y, r.w, r.h)
    }
}

pub const SNIP_PNG_OPAQUE: u32 = 1 << 0;
pub const SNIP_PNG_ADAPTIVE: u32 = 1 << 1;

pub const SNIP_STITCH_NO_MATCH: i64 = -1;
pub const SNIP_STITCH_FULL: i64 = -2;

/// Bytes a caller must provide for an image with this geometry.
fn image_len(height: usize, stride: usize) -> Option<usize> {
    stride.checked_mul(height).filter(|&len| len > 0)
}

/// # Safety
/// `bgra` must point to `stride * height` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn snip_encode_png(
    bgra: *const u8,
    width: usize,
    height: usize,
    stride: usize,
    crop: SnipRect,
    flags: u32,
    level: u32,
    dpi: u32,
) -> SnipBuffer {
    let Some(len) = image_len(height, stride) else { return SnipBuffer::empty() };
    if bgra.is_null() || stride < width.saturating_mul(4) {
        return SnipBuffer::empty();
    }
    let src = slice::from_raw_parts(bgra, len);
    let opts = png::Options {
        opaque: flags & SNIP_PNG_OPAQUE != 0,
        adaptive: flags & SNIP_PNG_ADAPTIVE != 0,
        level,
        dpi,
    };
    SnipBuffer::from_vec(png::encode(src, width, height, stride, crop.into(), opts))
}

/// # Safety
/// `buffer` must come from this library and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn snip_buffer_free(buffer: SnipBuffer) {
    if !buffer.ptr.is_null() {
        drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.cap));
    }
}

/// # Safety
/// `bgra` must point to `stride * height` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn snip_pixelate(
    bgra: *mut u8,
    width: usize,
    height: usize,
    stride: usize,
    region: SnipRect,
    block: usize,
) {
    let Some(len) = image_len(height, stride) else { return };
    if bgra.is_null() || stride < width.saturating_mul(4) {
        return;
    }
    effects::pixelate(slice::from_raw_parts_mut(bgra, len), width, height, stride, region.into(), block);
}

/// # Safety
/// `bgra` must point to `stride * height` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn snip_blur(
    bgra: *mut u8,
    width: usize,
    height: usize,
    stride: usize,
    region: SnipRect,
    radius: usize,
) {
    let Some(len) = image_len(height, stride) else { return };
    if bgra.is_null() || stride < width.saturating_mul(4) {
        return;
    }
    effects::blur(slice::from_raw_parts_mut(bgra, len), width, height, stride, region.into(), radius);
}

/// Creates a stitcher for frames of exactly `width` x `height` pixels.
/// `ignore_right` columns are left out of matching (overlay scrollbars).
#[no_mangle]
pub extern "C" fn snip_stitcher_new(width: usize, height: usize, ignore_right: usize) -> *mut stitch::Stitcher {
    Box::into_raw(Box::new(stitch::Stitcher::new(width, height, ignore_right)))
}

/// Feeds a frame. Returns the rows appended (0 if nothing new), or one of the
/// negative `SNIP_STITCH_*` codes if the frame was ignored.
///
/// # Safety
/// `stitcher` must be live; `bgra` must hold `stride * height` readable bytes
/// for the height the stitcher was created with.
#[no_mangle]
pub unsafe extern "C" fn snip_stitcher_push(stitcher: *mut stitch::Stitcher, bgra: *const u8, stride: usize) -> i64 {
    let Some(stitcher) = stitcher.as_mut() else { return SNIP_STITCH_NO_MATCH };
    let rows = stitcher.frame_height();
    let Some(len) = image_len(rows, stride) else { return SNIP_STITCH_NO_MATCH };
    if bgra.is_null() {
        return SNIP_STITCH_NO_MATCH;
    }
    match stitcher.push(slice::from_raw_parts(bgra, len), stride) {
        stitch::Push::Appended(rows) => rows as i64,
        stitch::Push::NoMatch => SNIP_STITCH_NO_MATCH,
        stitch::Push::Full => SNIP_STITCH_FULL,
    }
}

/// Height in pixels of the image `snip_stitcher_finish` would return now.
///
/// # Safety
/// `stitcher` must be live or null.
#[no_mangle]
pub unsafe extern "C" fn snip_stitcher_height(stitcher: *const stitch::Stitcher) -> usize {
    stitcher.as_ref().map_or(0, |s| s.stitched_height())
}

/// Consumes the stitcher and returns the image as tightly packed BGRA rows
/// (stride = width * 4). `out_height` receives the row count.
///
/// # Safety
/// `stitcher` must be live and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn snip_stitcher_finish(stitcher: *mut stitch::Stitcher, out_height: *mut usize) -> SnipBuffer {
    if stitcher.is_null() {
        return SnipBuffer::empty();
    }
    let (pixels, rows) = Box::from_raw(stitcher).finish();
    if let Some(out) = out_height.as_mut() {
        *out = rows;
    }
    if rows == 0 {
        return SnipBuffer::empty();
    }
    SnipBuffer::from_vec(pixels)
}

/// # Safety
/// `stitcher` must be live or null, and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn snip_stitcher_free(stitcher: *mut stitch::Stitcher) {
    if !stitcher.is_null() {
        drop(Box::from_raw(stitcher));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_roundtrip() {
        let (w, h) = (64usize, 40usize);
        let stride = w * 4;
        let mut pixels: Vec<u8> = (0..stride * h).map(|i| (i % 251) as u8 | 0x01).collect();
        for px in pixels.as_chunks_mut::<4>().0 {
            px[3] = 255;
        }
        unsafe {
            let all = SnipRect { x: 0, y: 0, w, h };
            let png = snip_encode_png(pixels.as_ptr(), w, h, stride, all, SNIP_PNG_OPAQUE, 1, 144);
            assert!(png.len > 8);
            assert_eq!(slice::from_raw_parts(png.ptr, 8), [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
            snip_buffer_free(png);

            snip_pixelate(pixels.as_mut_ptr(), w, h, stride, all, 8);
            snip_blur(pixels.as_mut_ptr(), w, h, stride, all, 4);

            // Bad input must be rejected, not dereferenced.
            assert!(snip_encode_png(std::ptr::null(), w, h, stride, all, 0, 1, 0).ptr.is_null());
            assert!(snip_encode_png(pixels.as_ptr(), w, h, w, all, 0, 1, 0).ptr.is_null());
            snip_buffer_free(SnipBuffer::empty());

            let stitcher = snip_stitcher_new(w, h, 0);
            assert_eq!(snip_stitcher_push(stitcher, pixels.as_ptr(), stride), h as i64);
            assert_eq!(snip_stitcher_push(stitcher, pixels.as_ptr(), stride), 0);
            assert_eq!(snip_stitcher_height(stitcher), h);
            let mut rows = 0usize;
            let image = snip_stitcher_finish(stitcher, &mut rows);
            assert_eq!((rows, image.len), (h, stride * h));
            snip_buffer_free(image);
            snip_stitcher_free(std::ptr::null_mut());
        }
    }
}
