//! Encode benchmark on a real screenshot:
//!   cargo run --release --example bench -- path/to/screenshot.png

use std::time::{Duration, Instant};

use snipster_core::{png as fast, Rect};

fn load_bgra(path: &str) -> (Vec<u8>, usize, usize) {
    let decoder = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).expect("open input")));
    let mut reader = decoder.read_info().expect("png header");
    let mut buf = vec![0; reader.output_buffer_size().expect("size")];
    let info = reader.next_frame(&mut buf).expect("png data");
    let channels = info.color_type.samples();
    assert!(info.bit_depth == png::BitDepth::Eight && channels >= 3, "need 8-bit RGB(A) input");
    let (w, h) = (info.width as usize, info.height as usize);
    let mut bgra = vec![255u8; w * h * 4];
    for (src, dst) in buf.chunks_exact(channels).zip(bgra.as_chunks_mut::<4>().0) {
        dst[0] = src[2];
        dst[1] = src[1];
        dst[2] = src[0];
    }
    (bgra, w, h)
}

fn best_of<T>(runs: usize, mut f: impl FnMut() -> T) -> (Duration, T) {
    let mut best = Duration::MAX;
    let mut out = None;
    for _ in 0..runs {
        let start = Instant::now();
        let value = f();
        best = best.min(start.elapsed());
        out = Some(value);
    }
    (best, out.unwrap())
}

fn reference(bgra: &[u8], w: usize, h: usize, compression: png::Compression) -> Vec<u8> {
    let rgb: Vec<u8> = bgra.as_chunks::<4>().0.iter().flat_map(|p| [p[2], p[1], p[0]]).collect();
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, w as u32, h as u32);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(compression);
    encoder.write_header().unwrap().write_image_data(&rgb).unwrap();
    out
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: bench <screenshot.png>");
    let (bgra, w, h) = load_bgra(&path);
    let megapixels = (w * h) as f64 / 1e6;
    println!("{w}x{h} ({megapixels:.1} MP), {} threads\n", rayon::current_num_threads());

    let report = |name: &str, time: Duration, bytes: usize| {
        let ms = time.as_secs_f64() * 1e3;
        println!("{name:<34} {ms:>8.2} ms {:>8.0} MP/s {:>8.2} MB", megapixels / time.as_secs_f64(), bytes as f64 / 1e6);
    };

    let full = Rect::new(0, 0, w, h);
    let variants = [
        ("snipster level 1 (clipboard)", fast::Options { opaque: true, level: 1, adaptive: false, dpi: 144 }),
        ("snipster level 1 adaptive", fast::Options { opaque: true, level: 1, adaptive: true, dpi: 144 }),
        ("snipster level 4 adaptive (file)", fast::Options { opaque: true, level: 4, adaptive: true, dpi: 144 }),
        ("snipster level 6 adaptive", fast::Options { opaque: true, level: 6, adaptive: true, dpi: 144 }),
        ("snipster level 9 adaptive", fast::Options { opaque: true, level: 9, adaptive: true, dpi: 144 }),
    ];
    for (name, opts) in variants {
        let (time, bytes) = best_of(7, || fast::encode(&bgra, w, h, w * 4, full, opts));
        report(name, time, bytes.len());
        let decoder = png::Decoder::new(std::io::Cursor::new(&bytes));
        let mut reader = decoder.read_info().unwrap();
        let mut decoded = vec![0; reader.output_buffer_size().unwrap()];
        reader.next_frame(&mut decoded).unwrap();
        let same = decoded.as_chunks::<3>().0.iter().zip(bgra.as_chunks::<4>().0).all(|(d, s)| *d == [s[2], s[1], s[0]]);
        assert!(same, "{name}: decoded pixels differ from the source");
    }

    let crop = Rect::new(w / 4, h / 4, (1600).min(w / 2), (1000).min(h / 2));
    let (time, bytes) = best_of(15, || fast::encode(&bgra, w, h, w * 4, crop, fast::Options { dpi: 144, ..Default::default() }));
    println!();
    report(&format!("snipster level 1, {}x{} crop", crop.w, crop.h), time, bytes.len());

    println!();
    for (name, compression) in [
        ("png crate Fastest (1 thread)", png::Compression::Fastest),
        ("png crate Fast (1 thread)", png::Compression::Fast),
        ("png crate Balanced (1 thread)", png::Compression::Balanced),
    ] {
        let (time, bytes) = best_of(3, || reference(&bgra, w, h, compression));
        report(name, time, bytes.len());
    }
}
