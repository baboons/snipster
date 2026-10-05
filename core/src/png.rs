//! Parallel PNG encoder for BGRA screen captures.
//!
//! A PNG's pixel data is one zlib stream, which normally forces single-threaded
//! compression. We split the image into horizontal bands, deflate each band on
//! its own core as a raw stream that ends on a byte boundary (sync flush), and
//! concatenate them. The Adler-32 trailer is stitched together from per-band
//! checksums, so nothing is ever processed twice.

use flate2::{Compress, Compression, FlushCompress, Status};
use rayon::prelude::*;

use crate::Rect;

const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// Bands smaller than this compress worse and aren't worth a thread hop.
const MIN_BAND_BYTES: usize = 192 * 1024;

#[derive(Clone, Copy, Debug)]
pub struct Options {
    /// Drop the alpha channel and write RGB. Screen captures are always opaque.
    pub opaque: bool,
    /// zlib level 1..=9. 1 is used for the clipboard, higher for files.
    pub level: u32,
    /// Pick the best filter per row instead of always using `Up`.
    pub adaptive: bool,
    /// Pixels per inch written to `pHYs` (144 for Retina captures). 0 omits it.
    pub dpi: u32,
}

impl Default for Options {
    fn default() -> Self {
        Options { opaque: true, level: 1, adaptive: false, dpi: 0 }
    }
}

struct Band {
    deflated: Vec<u8>,
    crc: u32,
    adler: u32,
    raw_len: usize,
}

/// Encodes `crop` of a premultiplied BGRA8 buffer as a PNG.
///
/// `src` must hold at least `stride * height` bytes; `crop` is clamped to the image.
pub fn encode(src: &[u8], width: usize, height: usize, stride: usize, crop: Rect, opts: Options) -> Vec<u8> {
    let crop = crop.clamped(width, height);
    if crop.w == 0 || crop.h == 0 {
        return Vec::new();
    }
    let bpp = if opts.opaque { 3 } else { 4 };
    let row_bytes = crop.w * bpp;
    let scanline = row_bytes + 1;

    let threads = rayon::current_num_threads().max(1);
    let by_size = (scanline * crop.h) / MIN_BAND_BYTES;
    let band_count = by_size.clamp(1, threads * 2).min(crop.h);
    let rows_per_band = crop.h.div_ceil(band_count);
    let band_count = crop.h.div_ceil(rows_per_band);

    let bands: Vec<Band> = (0..band_count)
        .into_par_iter()
        .map(|i| {
            let y0 = i * rows_per_band;
            let y1 = (y0 + rows_per_band).min(crop.h);
            let filtered = filter_band(src, stride, crop, y0, y1, bpp, opts.adaptive);
            let deflated = deflate_band(&filtered, opts.level, i + 1 == band_count);
            Band {
                crc: chunk_crc(b"IDAT", &deflated),
                adler: adler32(&filtered),
                raw_len: filtered.len(),
                deflated,
            }
        })
        .collect();

    let mut adler = 1u32;
    for band in &bands {
        adler = adler32_combine(adler, band.adler, band.raw_len);
    }

    let body: usize = bands.iter().map(|b| b.deflated.len() + 12).sum();
    let mut out = Vec::with_capacity(body + 128);
    out.extend_from_slice(&SIGNATURE);

    let mut ihdr = [0u8; 13];
    ihdr[0..4].copy_from_slice(&(crop.w as u32).to_be_bytes());
    ihdr[4..8].copy_from_slice(&(crop.h as u32).to_be_bytes());
    ihdr[8] = 8;
    ihdr[9] = if opts.opaque { 2 } else { 6 };
    write_chunk(&mut out, b"IHDR", &ihdr);
    // Captures are requested in sRGB, so tag them as such (perceptual intent).
    write_chunk(&mut out, b"sRGB", &[0]);
    if opts.dpi > 0 {
        let ppm = ((opts.dpi as f64) / 0.0254).round() as u32;
        let mut phys = [0u8; 9];
        phys[0..4].copy_from_slice(&ppm.to_be_bytes());
        phys[4..8].copy_from_slice(&ppm.to_be_bytes());
        phys[8] = 1;
        write_chunk(&mut out, b"pHYs", &phys);
    }

    // zlib header: deflate, 32K window, no preset dictionary, fastest.
    write_chunk(&mut out, b"IDAT", &[0x78, 0x01]);
    for band in &bands {
        out.extend_from_slice(&(band.deflated.len() as u32).to_be_bytes());
        out.extend_from_slice(b"IDAT");
        out.extend_from_slice(&band.deflated);
        out.extend_from_slice(&band.crc.to_be_bytes());
    }
    write_chunk(&mut out, b"IDAT", &adler.to_be_bytes());
    write_chunk(&mut out, b"IEND", &[]);
    out
}

fn write_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&chunk_crc(kind, data).to_be_bytes());
}

fn chunk_crc(kind: &[u8; 4], data: &[u8]) -> u32 {
    let mut hasher = crc32fast::Hasher::new();
    hasher.update(kind);
    hasher.update(data);
    hasher.finalize()
}

fn adler32(data: &[u8]) -> u32 {
    let mut hasher = simd_adler32::Adler32::new();
    hasher.write(data);
    hasher.finish()
}

/// Adler-32 of `A ++ B` from the checksums of `A` and `B` (zlib's `adler32_combine`).
fn adler32_combine(adler1: u32, adler2: u32, len2: usize) -> u32 {
    const BASE: u64 = 65521;
    let rem = (len2 as u64) % BASE;
    let a1 = (adler1 & 0xFFFF) as u64;
    let b1 = (adler1 >> 16) as u64;
    let a2 = (adler2 & 0xFFFF) as u64;
    let b2 = (adler2 >> 16) as u64;
    let a = (a1 + a2 + BASE - 1) % BASE;
    let b = (rem * a1 + b1 + b2 + BASE - rem) % BASE;
    ((b as u32) << 16) | a as u32
}

fn deflate_band(filtered: &[u8], level: u32, last: bool) -> Vec<u8> {
    let mut deflater = Compress::new(Compression::new(level.clamp(1, 9)), false);
    let mut out = Vec::with_capacity(filtered.len() / 3 + 1024);
    let flush = if last { FlushCompress::Finish } else { FlushCompress::Sync };
    loop {
        let consumed = deflater.total_in() as usize;
        let status = deflater
            .compress_vec(&filtered[consumed..], &mut out, flush)
            .expect("in-memory deflate cannot fail");
        if status == Status::StreamEnd {
            break;
        }
        // A sync flush is complete once all input is consumed and the
        // deflater stopped short of filling the buffer we gave it.
        let drained = deflater.total_in() as usize == filtered.len();
        if !last && drained && out.len() < out.capacity() {
            break;
        }
        if out.len() == out.capacity() {
            out.reserve(out.capacity().max(4096));
        }
    }
    out
}

/// Converts rows `y0..y1` of the crop to RGB(A) and applies PNG row filters.
fn filter_band(src: &[u8], stride: usize, crop: Rect, y0: usize, y1: usize, bpp: usize, adaptive: bool) -> Vec<u8> {
    let row_bytes = crop.w * bpp;
    let scanline = row_bytes + 1;
    let mut out = vec![0u8; scanline * (y1 - y0)];
    let mut prev = vec![0u8; row_bytes];
    let mut cur = vec![0u8; row_bytes];
    let mut scratch = if adaptive { vec![0u8; row_bytes * 2] } else { Vec::new() };

    let src_row = |y: usize| {
        let start = (crop.y + y) * stride + crop.x * 4;
        &src[start..start + crop.w * 4]
    };
    // The first row of a band is still filtered against the row above it,
    // so bands stay independent without hurting compression at the seams.
    if y0 > 0 {
        convert_row(src_row(y0 - 1), &mut prev, bpp);
    }

    for (y, line) in (y0..y1).zip(out.chunks_exact_mut(scanline)) {
        convert_row(src_row(y), &mut cur, bpp);
        let (tag, body) = line.split_first_mut().unwrap();
        if adaptive {
            *tag = filter_adaptive(&cur, &prev, body, &mut scratch, bpp);
        } else {
            *tag = 2;
            filter_up(&cur, &prev, body);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    out
}

#[inline]
fn convert_row(bgra: &[u8], out: &mut [u8], bpp: usize) {
    if bpp == 3 {
        bgra_to_rgb(bgra, out);
    } else {
        bgra_to_rgba_straight(bgra, out);
    }
}

#[cfg(target_arch = "aarch64")]
fn bgra_to_rgb(bgra: &[u8], out: &mut [u8]) {
    use std::arch::aarch64::*;
    let pixels = bgra.len() / 4;
    let simd = pixels / 16;
    // SAFETY: every load/store stays inside the first `simd * 16` pixels of
    // both slices, and NEON is a baseline feature on aarch64.
    unsafe {
        let mut s = bgra.as_ptr();
        let mut d = out.as_mut_ptr();
        for _ in 0..simd {
            let px = vld4q_u8(s);
            vst3q_u8(d, uint8x16x3_t(px.2, px.1, px.0));
            s = s.add(64);
            d = d.add(48);
        }
    }
    bgra_to_rgb_scalar(&bgra[simd * 64..], &mut out[simd * 48..]);
}

#[cfg(not(target_arch = "aarch64"))]
fn bgra_to_rgb(bgra: &[u8], out: &mut [u8]) {
    bgra_to_rgb_scalar(bgra, out);
}

fn bgra_to_rgb_scalar(bgra: &[u8], out: &mut [u8]) {
    for (s, d) in bgra.as_chunks::<4>().0.iter().zip(out.as_chunks_mut::<3>().0) {
        *d = [s[2], s[1], s[0]];
    }
}

/// PNG stores straight alpha; CoreGraphics hands us premultiplied.
fn bgra_to_rgba_straight(bgra: &[u8], out: &mut [u8]) {
    for (s, d) in bgra.as_chunks::<4>().0.iter().zip(out.as_chunks_mut::<4>().0) {
        let a = s[3] as u32;
        *d = if a == 255 {
            [s[2], s[1], s[0], 255]
        } else if a == 0 {
            [0, 0, 0, 0]
        } else {
            let un = |c: u8| (((c as u32) * 255 + a / 2) / a).min(255) as u8;
            [un(s[2]), un(s[1]), un(s[0]), a as u8]
        };
    }
}

#[inline]
fn filter_up(cur: &[u8], prev: &[u8], out: &mut [u8]) {
    for ((o, c), p) in out.iter_mut().zip(cur).zip(prev) {
        *o = c.wrapping_sub(*p);
    }
}

#[inline]
fn filter_sub(cur: &[u8], out: &mut [u8], bpp: usize) {
    out[..bpp].copy_from_slice(&cur[..bpp]);
    for i in bpp..cur.len() {
        out[i] = cur[i].wrapping_sub(cur[i - bpp]);
    }
}

#[inline]
fn filter_paeth(cur: &[u8], prev: &[u8], out: &mut [u8], bpp: usize) {
    for i in 0..bpp {
        out[i] = cur[i].wrapping_sub(prev[i]);
    }
    for i in bpp..cur.len() {
        let a = cur[i - bpp] as i16;
        let b = prev[i] as i16;
        let c = prev[i - bpp] as i16;
        let p = a + b - c;
        let (pa, pb, pc) = ((p - a).abs(), (p - b).abs(), (p - c).abs());
        let pred = if pa <= pb && pa <= pc {
            a
        } else if pb <= pc {
            b
        } else {
            c
        };
        out[i] = cur[i].wrapping_sub(pred as u8);
    }
}

/// Sum of absolute values when bytes are read as signed: the usual libpng
/// heuristic for "how compressible is this filtered row".
#[inline]
fn row_cost(row: &[u8]) -> u64 {
    row.iter().map(|&b| (b as i8).unsigned_abs() as u64).sum()
}

fn filter_adaptive(cur: &[u8], prev: &[u8], out: &mut [u8], scratch: &mut [u8], bpp: usize) -> u8 {
    let (sub, paeth) = scratch.split_at_mut(cur.len());
    filter_up(cur, prev, out);
    let up_cost = row_cost(out);
    if up_cost == 0 {
        return 2;
    }
    filter_sub(cur, sub, bpp);
    let sub_cost = row_cost(sub);
    filter_paeth(cur, prev, paeth, bpp);
    let paeth_cost = row_cost(paeth);

    if sub_cost < up_cost && sub_cost <= paeth_cost {
        out.copy_from_slice(sub);
        1
    } else if paeth_cost < up_cost {
        out.copy_from_slice(paeth);
        4
    } else {
        2
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(png_bytes: &[u8]) -> (png::OutputInfo, Vec<u8>, Option<png::PixelDimensions>) {
        let decoder = png::Decoder::new(std::io::Cursor::new(png_bytes));
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut buf).unwrap();
        buf.truncate(info.buffer_size());
        let dims = reader.info().pixel_dims;
        (info, buf, dims)
    }

    /// Deterministic noisy-but-compressible BGRA test image with row padding.
    fn test_image(w: usize, h: usize, stride: usize, opaque: bool) -> Vec<u8> {
        let mut buf = vec![0xEEu8; stride * h];
        let mut seed = 0x9E3779B97F4A7C15u64;
        for y in 0..h {
            for x in 0..w {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let noise = if (x / 37 + y / 23) % 3 == 0 { (seed >> 56) as u8 } else { 0 };
                let a = if opaque { 255u32 } else { ((x * 255) / w.max(1)) as u32 };
                let px = [(x as u8) ^ noise, (y as u8).wrapping_add(noise), ((x + y) / 7) as u8];
                let i = y * stride + x * 4;
                for c in 0..3 {
                    buf[i + c] = ((px[c] as u32 * a + 127) / 255) as u8;
                }
                buf[i + 3] = a as u8;
            }
        }
        buf
    }

    fn expect_rgb(src: &[u8], stride: usize, crop: Rect) -> Vec<u8> {
        let mut out = Vec::new();
        for y in crop.y..crop.y + crop.h {
            for x in crop.x..crop.x + crop.w {
                let i = y * stride + x * 4;
                out.extend_from_slice(&[src[i + 2], src[i + 1], src[i]]);
            }
        }
        out
    }

    #[test]
    fn roundtrips_opaque_across_many_bands() {
        let (w, h) = (1203, 911);
        let stride = w * 4 + 20;
        let src = test_image(w, h, stride, true);
        for adaptive in [false, true] {
            for level in [1, 6] {
                let opts = Options { opaque: true, level, adaptive, dpi: 144 };
                let bytes = encode(&src, w, h, stride, Rect::new(0, 0, w, h), opts);
                let (info, pixels, dims) = decode(&bytes);
                assert_eq!((info.width, info.height), (w as u32, h as u32));
                assert_eq!(info.color_type, png::ColorType::Rgb);
                assert_eq!(pixels, expect_rgb(&src, stride, Rect::new(0, 0, w, h)));
                let dims = dims.unwrap();
                assert_eq!((dims.xppu, dims.yppu), (5669, 5669));
            }
        }
    }

    #[test]
    fn crops_and_clamps() {
        let (w, h) = (640, 480);
        let stride = w * 4;
        let src = test_image(w, h, stride, true);
        let crop = Rect::new(13, 29, 301, 217);
        let bytes = encode(&src, w, h, stride, crop, Options::default());
        let (info, pixels, _) = decode(&bytes);
        assert_eq!((info.width, info.height), (301, 217));
        assert_eq!(pixels, expect_rgb(&src, stride, crop));

        let bytes = encode(&src, w, h, stride, Rect::new(600, 400, 500, 500), Options::default());
        let (info, _, _) = decode(&bytes);
        assert_eq!((info.width, info.height), (40, 80));
        assert!(encode(&src, w, h, stride, Rect::new(700, 0, 10, 10), Options::default()).is_empty());
    }

    #[test]
    fn alpha_is_unpremultiplied() {
        let (w, h) = (256, 64);
        let stride = w * 4;
        let src = test_image(w, h, stride, false);
        let opts = Options { opaque: false, ..Options::default() };
        let bytes = encode(&src, w, h, stride, Rect::new(0, 0, w, h), opts);
        let (info, pixels, _) = decode(&bytes);
        assert_eq!(info.color_type, png::ColorType::Rgba);
        for (s, d) in src.as_chunks::<4>().0.iter().zip(pixels.as_chunks::<4>().0) {
            assert_eq!(d[3], s[3]);
            // Re-premultiplying must land back on the source within rounding.
            for c in 0..3 {
                let re = (d[c] as u32 * d[3] as u32 + 127) / 255;
                assert!((re as i32 - s[2 - c] as i32).abs() <= 1, "{re} vs {}", s[2 - c]);
            }
        }
    }

    #[test]
    fn single_pixel() {
        let src = [10u8, 20, 30, 255];
        let bytes = encode(&src, 1, 1, 4, Rect::new(0, 0, 1, 1), Options::default());
        let (_, pixels, _) = decode(&bytes);
        assert_eq!(pixels, [30, 20, 10]);
    }

    #[test]
    fn adler_combine_matches_direct() {
        let data: Vec<u8> = (0..200_000u32).map(|i| (i.wrapping_mul(2654435761) >> 24) as u8).collect();
        for split in [0, 1, 65521, 100_000, 199_999, 200_000] {
            let (a, b) = data.split_at(split);
            assert_eq!(adler32_combine(adler32(a), adler32(b), b.len()), adler32(&data));
        }
    }
}
