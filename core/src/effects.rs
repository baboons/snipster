//! In-place redaction effects on premultiplied BGRA8 buffers.

use rayon::prelude::*;

use crate::Rect;

/// Replaces `region` with a mosaic of `block`-sized cells, each the average of
/// the pixels it covers. Cells are anchored to the region's top-left corner.
pub fn pixelate(buf: &mut [u8], width: usize, height: usize, stride: usize, region: Rect, block: usize) {
    let region = region.clamped(width, height);
    let block = block.max(1);
    if region.w == 0 || region.h == 0 || block == 1 {
        return;
    }
    let mut by = 0;
    while by < region.h {
        let bh = block.min(region.h - by);
        let mut bx = 0;
        while bx < region.w {
            let bw = block.min(region.w - bx);
            let mut sum = [0u32; 4];
            for y in 0..bh {
                let row = (region.y + by + y) * stride + (region.x + bx) * 4;
                for px in buf[row..row + bw * 4].as_chunks::<4>().0 {
                    for c in 0..4 {
                        sum[c] += px[c] as u32;
                    }
                }
            }
            let n = (bw * bh) as u32;
            let avg = [
                ((sum[0] + n / 2) / n) as u8,
                ((sum[1] + n / 2) / n) as u8,
                ((sum[2] + n / 2) / n) as u8,
                ((sum[3] + n / 2) / n) as u8,
            ];
            for y in 0..bh {
                let row = (region.y + by + y) * stride + (region.x + bx) * 4;
                for px in buf[row..row + bw * 4].as_chunks_mut::<4>().0 {
                    *px = avg;
                }
            }
            bx += block;
        }
        by += block;
    }
}

/// Gaussian-like blur of `region` (three box passes). Edges clamp to the
/// region itself, so nothing outside it bleeds in or out.
pub fn blur(buf: &mut [u8], width: usize, height: usize, stride: usize, region: Rect, radius: usize) {
    let region = region.clamped(width, height);
    if region.w == 0 || region.h == 0 || radius == 0 {
        return;
    }
    let (w, h) = (region.w, region.h);
    let row_len = w * 4;

    // Work on a tightly packed copy so both passes are cache friendly.
    let mut a = vec![0u8; row_len * h];
    for (y, row) in a.chunks_exact_mut(row_len).enumerate() {
        let start = (region.y + y) * stride + region.x * 4;
        row.copy_from_slice(&buf[start..start + row_len]);
    }
    let mut b = vec![0u8; row_len * h];

    for r in box_radii(radius as f64) {
        box_horizontal(&a, &mut b, w, r);
        box_vertical(&b, &mut a, w, h, r);
    }

    for (y, row) in a.chunks_exact(row_len).enumerate() {
        let start = (region.y + y) * stride + region.x * 4;
        buf[start..start + row_len].copy_from_slice(row);
    }
}

/// Radii of three box blurs that together approximate a Gaussian of `sigma`.
fn box_radii(sigma: f64) -> [usize; 3] {
    let ideal = (12.0 * sigma * sigma / 3.0 + 1.0).sqrt();
    let mut lower = ideal.floor() as usize;
    if lower.is_multiple_of(2) {
        lower = lower.saturating_sub(1).max(1);
    }
    let upper = lower + 2;
    let lf = lower as f64;
    let m = ((12.0 * sigma * sigma - 3.0 * lf * lf - 12.0 * lf - 9.0) / (-4.0 * lf - 4.0)).round();
    let m = m.clamp(0.0, 3.0) as usize;
    let mut radii = [0usize; 3];
    for (i, radius) in radii.iter_mut().enumerate() {
        let size = if i < m { lower } else { upper };
        *radius = (size - 1) / 2;
    }
    radii
}

fn box_horizontal(src: &[u8], dst: &mut [u8], w: usize, r: usize) {
    if r == 0 {
        dst.copy_from_slice(src);
        return;
    }
    let row_len = w * 4;
    let window = (2 * r + 1) as u32;
    dst.par_chunks_exact_mut(row_len)
        .zip(src.par_chunks_exact(row_len))
        .for_each(|(out, row)| {
            let px = |x: isize| {
                let x = x.clamp(0, w as isize - 1) as usize * 4;
                [row[x] as u32, row[x + 1] as u32, row[x + 2] as u32, row[x + 3] as u32]
            };
            let mut sum = [0u32; 4];
            for x in -(r as isize)..=(r as isize) {
                let p = px(x);
                for c in 0..4 {
                    sum[c] += p[c];
                }
            }
            for x in 0..w {
                for c in 0..4 {
                    out[x * 4 + c] = ((sum[c] + window / 2) / window) as u8;
                }
                let add = px(x as isize + r as isize + 1);
                let sub = px(x as isize - r as isize);
                for c in 0..4 {
                    sum[c] = sum[c] + add[c] - sub[c];
                }
            }
        });
}

fn box_vertical(src: &[u8], dst: &mut [u8], w: usize, h: usize, r: usize) {
    if r == 0 {
        dst.copy_from_slice(src);
        return;
    }
    let row_len = w * 4;
    let window = (2 * r + 1) as u32;
    // Split into vertical strips so each thread keeps a small running-sum
    // buffer hot while walking down the image row by row.
    let strip = (w.div_ceil(rayon::current_num_threads().max(1))).max(64);
    let strips: Vec<(usize, usize)> = (0..w).step_by(strip).map(|x| (x, (x + strip).min(w))).collect();
    let dst_addr = dst.as_mut_ptr() as usize;

    strips.into_par_iter().for_each(|(x0, x1)| {
        let cols = (x1 - x0) * 4;
        let row = |y: isize| {
            let y = y.clamp(0, h as isize - 1) as usize;
            &src[y * row_len + x0 * 4..y * row_len + x0 * 4 + cols]
        };
        let mut sum = vec![0u32; cols];
        for y in -(r as isize)..=(r as isize) {
            for (s, v) in sum.iter_mut().zip(row(y)) {
                *s += *v as u32;
            }
        }
        for y in 0..h {
            // SAFETY: strips cover disjoint column ranges, so every thread
            // writes a distinct set of bytes inside `dst`.
            let out = unsafe {
                std::slice::from_raw_parts_mut((dst_addr as *mut u8).add(y * row_len + x0 * 4), cols)
            };
            for (o, s) in out.iter_mut().zip(&sum) {
                *o = ((*s + window / 2) / window) as u8;
            }
            let add = row(y as isize + r as isize + 1);
            let sub = row(y as isize - r as isize);
            for ((s, a), b) in sum.iter_mut().zip(add).zip(sub) {
                *s = *s + *a as u32 - *b as u32;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn checker(w: usize, h: usize, stride: usize) -> Vec<u8> {
        let mut buf = vec![7u8; stride * h];
        for y in 0..h {
            for x in 0..w {
                let v = if (x + y) % 2 == 0 { 255 } else { 0 };
                buf[y * stride + x * 4..y * stride + x * 4 + 4].copy_from_slice(&[v, v, v, 255]);
            }
        }
        buf
    }

    #[test]
    fn pixelate_averages_blocks_and_respects_region() {
        let (w, h, stride) = (32, 32, 32 * 4 + 8);
        let mut buf = checker(w, h, stride);
        let original = buf.clone();
        pixelate(&mut buf, w, h, stride, Rect::new(8, 8, 16, 16), 4);
        for y in 0..h {
            for x in 0..w {
                let px = &buf[y * stride + x * 4..y * stride + x * 4 + 4];
                if (8..24).contains(&x) && (8..24).contains(&y) {
                    assert_eq!(px, [128, 128, 128, 255]);
                } else {
                    assert_eq!(px, &original[y * stride + x * 4..y * stride + x * 4 + 4]);
                }
            }
            // Row padding must be left alone.
            assert_eq!(buf[y * stride + w * 4..(y + 1) * stride], original[y * stride + w * 4..(y + 1) * stride]);
        }
    }

    #[test]
    fn blur_smooths_and_preserves_flat_colour() {
        let (w, h, stride) = (64, 48, 64 * 4);
        let mut buf = checker(w, h, stride);
        let original = buf.clone();
        blur(&mut buf, w, h, stride, Rect::new(4, 4, 40, 30), 6);
        let center = &buf[20 * stride + 20 * 4..20 * stride + 20 * 4 + 4];
        assert!((center[0] as i32 - 127).abs() <= 3, "{center:?}");
        assert_eq!(center[3], 255);
        assert_eq!(buf[..4 * stride], original[..4 * stride]);
        assert_eq!(&buf[20 * stride + 50 * 4..20 * stride + 54 * 4], &original[20 * stride + 50 * 4..20 * stride + 54 * 4]);

        let mut flat = vec![200u8; stride * h];
        blur(&mut flat, w, h, stride, Rect::new(0, 0, w, h), 9);
        assert!(flat.iter().all(|&v| v == 200));
    }

    #[test]
    fn degenerate_inputs_are_noops() {
        let (w, h, stride) = (8, 8, 32);
        let mut buf = checker(w, h, stride);
        let original = buf.clone();
        blur(&mut buf, w, h, stride, Rect::new(20, 20, 4, 4), 5);
        pixelate(&mut buf, w, h, stride, Rect::new(0, 0, 8, 8), 1);
        blur(&mut buf, w, h, stride, Rect::new(0, 0, 8, 8), 0);
        assert_eq!(buf, original);
        // Radius far larger than the region must not panic.
        blur(&mut buf, w, h, stride, Rect::new(1, 1, 3, 2), 500);
        pixelate(&mut buf, w, h, stride, Rect::new(1, 1, 3, 2), 500);
    }
}
