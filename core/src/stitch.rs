//! Incremental stitcher for scrolling captures.
//!
//! Frames of the same screen region arrive while the user scrolls. For each
//! frame we find how far the content moved since the last accepted frame and
//! append only the rows that are new. Rows that never move (sticky headers and
//! footers) are detected per frame pair and kept out of the match, so the
//! result has one header on top and one footer at the bottom.
//!
//! Rows are compared through a coarse signature rather than byte for byte:
//! two captures of the same content are not bit-identical in practice (the
//! compositor re-rasterises text, colour conversion rounds differently), and
//! an exact match would reject every real-world frame.

use rayon::prelude::*;

/// Hard cap on the stitched image, to keep a runaway capture from eating RAM.
const MAX_CANVAS_BYTES: usize = 1 << 30;
/// Share of overlapping rows allowed to differ (carets, hover states, the
/// fade a scroll view draws along its edges).
const MISMATCH_TOLERANCE_PERCENT: usize = 8;
/// A match needs at least this many overlapping rows...
const MIN_OVERLAP_ROWS: usize = 24;
/// ...of which this many must carry vertical detail, so blank areas can't match by accident.
const MIN_DETAIL_ROWS: usize = 8;
/// Horizontal slices each row is summed into.
const BUCKETS: usize = 32;
/// Rows count as equal when every slice differs by less than this many grey
/// levels per byte on average. Capture noise stays well under one level.
const LEVEL_TOLERANCE: f32 = 1.5;

/// Per-slice byte sums of one row: cheap to compare, and insensitive to the
/// one-or-two-level differences between two captures of the same pixels.
type Signature = [u32; BUCKETS];

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Push {
    /// Rows appended to the canvas. Zero means the frame showed nothing new.
    Appended(usize),
    /// The frame could not be aligned with the previous one (scrolled too far,
    /// scrolled backwards, or the content changed). It was ignored.
    NoMatch,
    /// The canvas hit its size cap. The frame was ignored.
    Full,
}

pub struct Stitcher {
    width: usize,
    height: usize,
    /// Columns at the right edge excluded from matching (overlay scrollbars).
    ignore_right: usize,
    canvas: Vec<u8>,
    prev: Vec<u8>,
    prev_rows: Vec<Signature>,
    /// Rows of `prev` already on the canvas: `prev[..tail]` is its bottom edge.
    tail: usize,
    has_frame: bool,
}

impl Stitcher {
    pub fn new(width: usize, height: usize, ignore_right: usize) -> Self {
        Stitcher {
            width,
            height,
            ignore_right: ignore_right.min(width / 2),
            canvas: Vec::new(),
            prev: Vec::new(),
            prev_rows: Vec::new(),
            tail: 0,
            has_frame: false,
        }
    }

    pub fn width(&self) -> usize {
        self.width
    }

    /// Height every pushed frame must have.
    pub fn frame_height(&self) -> usize {
        self.height
    }

    /// Height of the image `finish` would produce right now.
    pub fn stitched_height(&self) -> usize {
        if !self.has_frame {
            return 0;
        }
        self.canvas.len() / self.row_len() + (self.height - self.tail)
    }

    fn row_len(&self) -> usize {
        self.width * 4
    }

    /// Feeds one BGRA frame of exactly `width` x `height` pixels.
    pub fn push(&mut self, frame: &[u8], stride: usize) -> Push {
        let row_len = self.row_len();
        if self.width == 0 || self.height == 0 || stride < row_len {
            return Push::NoMatch;
        }
        let mut cur = vec![0u8; row_len * self.height];
        cur.par_chunks_exact_mut(row_len).enumerate().for_each(|(y, row)| {
            row.copy_from_slice(&frame[y * stride..y * stride + row_len]);
        });
        let compared = (self.width - self.ignore_right) * 4;
        let rows: Vec<Signature> = cur.par_chunks_exact(row_len).map(|row| signature(&row[..compared])).collect();
        let tolerance = (compared.div_ceil(BUCKETS) as f32 * LEVEL_TOLERANCE) as u32;

        if !self.has_frame {
            self.canvas.extend_from_slice(&cur);
            self.prev = cur;
            self.prev_rows = rows;
            self.tail = self.height;
            self.has_frame = true;
            return Push::Appended(self.height);
        }

        let h = self.height;
        let same = |i: usize| rows_match(&rows[i], &self.prev_rows[i], tolerance);
        let top = (0..h).take_while(|&i| same(i)).count();
        if top == h {
            return Push::Appended(0);
        }
        let bottom_static = (0..h).rev().take_while(|&i| same(i)).count();
        let bottom = h - bottom_static;

        let Some(shift) = find_shift(&self.prev_rows, &rows, top, bottom, tolerance) else {
            return Push::NoMatch;
        };
        if self.canvas.len() + (shift + bottom.saturating_sub(self.tail)) * row_len > MAX_CANVAS_BYTES {
            return Push::Full;
        }

        // Make the canvas end exactly at the bottom of the moving band of
        // `prev`, then add the rows that scrolled into view.
        if self.tail > bottom {
            self.canvas.truncate(self.canvas.len() - (self.tail - bottom) * row_len);
        } else {
            self.canvas.extend_from_slice(&self.prev[self.tail * row_len..bottom * row_len]);
        }
        self.canvas.extend_from_slice(&cur[(bottom - shift) * row_len..bottom * row_len]);
        self.tail = bottom;
        self.prev = cur;
        self.prev_rows = rows;
        Push::Appended(shift)
    }

    /// Returns the stitched image as tightly packed BGRA rows plus its height.
    pub fn finish(mut self) -> (Vec<u8>, usize) {
        if !self.has_frame {
            return (Vec::new(), 0);
        }
        let row_len = self.row_len();
        self.canvas.extend_from_slice(&self.prev[self.tail * row_len..]);
        let rows = self.canvas.len() / row_len;
        (self.canvas, rows)
    }
}

/// Finds `d > 0` such that `cur[i]` matches `prev[i + d]` across the moving
/// band `top..bottom`, i.e. the content moved up by `d` rows.
fn find_shift(prev: &[Signature], cur: &[Signature], top: usize, bottom: usize, tolerance: u32) -> Option<usize> {
    let band = bottom - top;
    if band <= MIN_OVERLAP_ROWS {
        return None;
    }
    // A row has detail when it differs from the row above it. Runs of
    // similar rows line up at any offset and say nothing about the shift.
    let detail: Vec<bool> = (0..cur.len())
        .map(|i| i > 0 && !rows_match(&cur[i], &cur[i - 1], tolerance))
        .collect();

    // Scroll views fade their content along the top and bottom edges, so the
    // outermost rows of the band are left out of the comparison.
    let margin = (band / 16).min(24);
    let usable = band - 2 * margin;
    if usable <= MIN_OVERLAP_ROWS {
        return None;
    }

    // (mismatches, overlap, shift) of every offset that lines up well enough.
    let candidates: Vec<(usize, usize, usize)> = (1..=usable - MIN_OVERLAP_ROWS)
        .into_par_iter()
        .filter_map(|shift| {
            let overlap = usable - shift;
            let budget = overlap * MISMATCH_TOLERANCE_PERCENT / 100;
            let mut mismatches = 0;
            let mut detail_rows = 0;
            for i in top + margin..bottom - margin - shift {
                if rows_match(&cur[i], &prev[i + shift], tolerance) {
                    detail_rows += detail[i] as usize;
                } else {
                    mismatches += 1;
                    if mismatches > budget {
                        return None;
                    }
                }
            }
            (detail_rows >= MIN_DETAIL_ROWS).then_some((mismatches, overlap, shift))
        })
        .collect();

    // Lowest mismatch ratio wins (compared without floats); ties go to the
    // smaller shift, which is the likelier one between two close frames.
    candidates
        .into_iter()
        .min_by(|a, b| (a.0 * b.1).cmp(&(b.0 * a.1)).then(a.2.cmp(&b.2)))
        .map(|(_, _, shift)| shift)
}

fn signature(row: &[u8]) -> Signature {
    let mut sums = [0u32; BUCKETS];
    let bucket = row.len().div_ceil(BUCKETS).max(1);
    for (sum, bytes) in sums.iter_mut().zip(row.chunks(bucket)) {
        *sum = bytes.iter().map(|&b| b as u32).sum();
    }
    sums
}

#[inline]
fn rows_match(a: &Signature, b: &Signature, tolerance: u32) -> bool {
    a.iter().zip(b).all(|(x, y)| x.abs_diff(*y) <= tolerance)
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 96;

    /// A tall "page": every row is unique-ish, with some blank stretches.
    fn document(rows: usize) -> Vec<u8> {
        let mut doc = vec![0u8; rows * W * 4];
        let mut seed = 0x243F_6A88_85A3_08D3u64;
        for y in 0..rows {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let blank = (y / 40) % 4 == 3;
            for x in 0..W {
                let v = if blank { 250 } else { ((seed >> ((x % 8) * 8)) as u8) ^ (x as u8) };
                doc[(y * W + x) * 4..(y * W + x) * 4 + 4].copy_from_slice(&[v, v ^ 0x55, v.wrapping_add(y as u8), 255]);
            }
        }
        doc
    }

    fn solid(rows: usize, v: u8) -> Vec<u8> {
        let mut out = Vec::new();
        for y in 0..rows {
            for x in 0..W {
                out.extend_from_slice(&[v, (x as u8).wrapping_mul(3), (y as u8).wrapping_mul(17) ^ v, 255]);
            }
        }
        out
    }

    /// Renders the viewport at scroll offset `at`, with optional sticky bars
    /// and `pad` bytes of row padding.
    fn viewport(doc: &[u8], at: usize, h: usize, header: &[u8], footer: &[u8], pad: usize) -> (Vec<u8>, usize) {
        let row = W * 4;
        let mut tight = doc[at * row..(at + h) * row].to_vec();
        tight[..header.len()].copy_from_slice(header);
        let start = tight.len() - footer.len();
        tight[start..].copy_from_slice(footer);
        let stride = row + pad;
        let mut padded = vec![0xABu8; stride * h];
        for y in 0..h {
            padded[y * stride..y * stride + row].copy_from_slice(&tight[y * row..(y + 1) * row]);
        }
        (padded, stride)
    }

    #[test]
    fn stitches_plain_scroll() {
        let doc = document(1200);
        let h = 300;
        let mut stitcher = Stitcher::new(W, h, 0);
        let offsets = [0, 0, 37, 120, 121, 260, 500, 500, 731, 900];
        let mut last = 0;
        for (n, &at) in offsets.iter().enumerate() {
            let (frame, stride) = viewport(&doc, at, h, &[], &[], 12);
            let expected = if n == 0 { Push::Appended(h) } else { Push::Appended(at - last) };
            assert_eq!(stitcher.push(&frame, stride), expected, "frame {n} at {at}");
            last = at;
            assert_eq!(stitcher.stitched_height(), at + h);
        }
        let (image, rows) = stitcher.finish();
        assert_eq!(rows, 900 + h);
        assert!(image == doc[..rows * W * 4]);
    }

    #[test]
    fn keeps_sticky_header_and_footer_once() {
        let doc = document(1500);
        let h = 320;
        let header = solid(28, 30);
        let footer = solid(19, 200);
        let mut stitcher = Stitcher::new(W, h, 0);
        let offsets = [0, 55, 180, 181, 380, 580];
        for &at in &offsets {
            let (frame, stride) = viewport(&doc, at, h, &header, &footer, 0);
            assert!(matches!(stitcher.push(&frame, stride), Push::Appended(_)), "at {at}");
        }
        let (image, rows) = stitcher.finish();
        let row = W * 4;
        let mut expected = header.clone();
        expected.extend_from_slice(&doc[28 * row..(580 + h - 19) * row]);
        expected.extend_from_slice(&footer);
        assert_eq!(rows, expected.len() / row);
        assert!(image == expected);
    }

    #[test]
    fn ignores_jumps_and_backward_scrolls_then_recovers() {
        let doc = document(2000);
        let h = 300;
        let mut stitcher = Stitcher::new(W, h, 0);
        let push = |s: &mut Stitcher, at: usize| {
            let (frame, stride) = viewport(&doc, at, h, &[], &[], 0);
            s.push(&frame, stride)
        };
        assert_eq!(push(&mut stitcher, 100), Push::Appended(h));
        assert_eq!(push(&mut stitcher, 200), Push::Appended(100));
        // Jumped a whole screen: nothing overlaps.
        assert_eq!(push(&mut stitcher, 900), Push::NoMatch);
        // Scrolled back above the last accepted frame.
        assert_eq!(push(&mut stitcher, 150), Push::NoMatch);
        assert_eq!(stitcher.stitched_height(), 100 + h);
        // Back in range: picks up where it left off.
        assert_eq!(push(&mut stitcher, 330), Push::Appended(130));
        let (image, rows) = stitcher.finish();
        assert_eq!(rows, 230 + h);
        assert!(image == doc[100 * W * 4..(100 + rows) * W * 4]);
    }

    #[test]
    fn tolerates_noise_and_ignores_scrollbar_columns() {
        let doc = document(1000);
        let h = 300;
        let mut stitcher = Stitcher::new(W, h, 8);
        let (frame, stride) = viewport(&doc, 0, h, &[], &[], 0);
        stitcher.push(&frame, stride);

        let (mut frame, stride) = viewport(&doc, 90, h, &[], &[], 0);
        // A moving scrollbar thumb in the ignored columns...
        for y in 40..120 {
            frame[y * stride + (W - 3) * 4] ^= 0xFF;
        }
        // ...and a hover highlight across a handful of rows.
        for y in 150..156 {
            for x in 10..60 {
                frame[y * stride + x * 4] ^= 0xFF;
            }
        }
        assert_eq!(stitcher.push(&frame, stride), Push::Appended(90));
    }

    /// Two captures of the same pixels differ by a level or two here and
    /// there, and scroll views fade their edges. Neither may break alignment.
    #[test]
    fn tolerates_capture_noise_and_edge_fades() {
        let doc = document(1400);
        let h = 320;
        let mut stitcher = Stitcher::new(W, h, 0);
        let mut seed = 0x1234_5678_9ABC_DEF0u64;
        let mut at = 0;
        for (n, step) in [0usize, 36, 80, 146, 9, 220].into_iter().enumerate() {
            at += step;
            let (mut frame, stride) = viewport(&doc, at, h, &[], &[], 4);
            for y in 0..h {
                for x in 0..W {
                    seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    if seed >> 61 == 0 {
                        let px = &mut frame[y * stride + x * 4];
                        *px = px.saturating_add(((seed >> 40) % 3) as u8);
                    }
                }
            }
            // The top rows are washed out, as under a translucent toolbar.
            for y in 0..10 {
                for x in 0..W * 4 {
                    let byte = &mut frame[y * stride + x];
                    *byte = byte.saturating_add((10 - y as u8) * 6);
                }
            }
            let expected = if n == 0 { h } else { step };
            assert_eq!(stitcher.push(&frame, stride), Push::Appended(expected), "frame {n} at {at}");
        }
        assert_eq!(stitcher.stitched_height(), at + h);
    }

    #[test]
    fn blank_content_does_not_false_match() {
        let h = 200;
        let mut stitcher = Stitcher::new(W, h, 0);
        let mut frame = vec![255u8; W * 4 * h];
        stitcher.push(&frame, W * 4);
        // One changed row in an otherwise blank frame gives no evidence of a scroll.
        frame[100 * W * 4] = 0;
        assert_eq!(stitcher.push(&frame, W * 4), Push::NoMatch);
        let empty = Stitcher::new(W, h, 0);
        assert_eq!(empty.finish().1, 0);
    }
}
