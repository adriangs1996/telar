// Telar patch: measure only the embedded font; never inspect host fonts or caches.
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::Mutex;
use ttf_parser::{Face, GlyphId};
use crate::unicode_width::{Cluster, consume_cluster, is_cjk_wide_char};

static TEXT_MEASURER: Lazy<Mutex<FontFace>> = Lazy::new(|| {
    let data = include_bytes!("../../../../../src/assets/IBMPlexSans-Regular.ttf").to_vec();
    let units_per_em = Face::parse(&data, 0).expect("embedded font").units_per_em().max(1);
    Mutex::new(FontFace::new(data, 0, units_per_em))
});

pub fn measure_text_width(text: &str, font_size: f32, _font_family: &str) -> Option<f32> {
    if text.is_empty() || font_size <= 0.0 { return Some(0.0); }
    TEXT_MEASURER.lock().ok()?.measure_width(&text.replace('\t', "    "), font_size)
}

pub fn average_char_width(font_family: &str, font_size: f32) -> Option<f32> {
    if font_size <= 0.0 { return None; }
    let sample = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    Some(measure_text_width(sample, font_size, font_family)? / sample.len() as f32)
}

struct FontFace {
    data: Vec<u8>,
    index: u32,
    units_per_em: u16,
    ascii_advances: Option<[u16; 128]>,
    glyph_cache: HashMap<char, Option<u16>>,
    advance_cache: HashMap<u16, u16>,
}

impl FontFace {
    fn new(data: Vec<u8>, index: u32, units_per_em: u16) -> Self {
        let ascii_advances = Face::parse(&data, index).ok().map(|parsed| {
            let mut advances = [0u16; 128];
            for byte in 0u8..=127 {
                let ch = byte as char;
                if let Some(glyph_id) = parsed.glyph_index(ch) {
                    advances[byte as usize] = parsed.glyph_hor_advance(glyph_id).unwrap_or(0);
                }
            }
            advances
        });
        Self {
            data,
            index,
            units_per_em,
            ascii_advances,
            glyph_cache: HashMap::new(),
            advance_cache: HashMap::new(),
        }
    }

    fn measure_width(&mut self, text: &str, font_size: f32) -> Option<f32> {
        let scale = font_size / self.units_per_em as f32;
        let fallback = font_size * 0.56;

        if text.is_ascii()
            && let Some(advances) = &self.ascii_advances
        {
            let mut width = 0.0f32;
            for byte in text.as_bytes() {
                if *byte == b'\n' {
                    continue;
                }
                let advance = advances[*byte as usize];
                if advance == 0 {
                    width += fallback;
                } else {
                    width += advance as f32 * scale;
                }
            }
            return Some(width.max(0.0));
        }

        let face = Face::parse(&self.data, self.index).ok()?;
        let scale = font_size / self.units_per_em as f32;
        let mut width = 0.0f32;
        let chars: Vec<char> = text.chars().collect();
        let mut idx = 0usize;

        while idx < chars.len() {
            let ch = chars[idx];
            if ch == '\n' {
                idx += 1;
                continue;
            }

            // Mirror fallback_text_width grapheme-cluster handling so both
            // measurement paths agree on widths for CJK ideographs, kana,
            // hangul, fullwidth chars, and emoji sequences. The OS will
            // render these via system font fallback (e.g. PingFang on iOS)
            // at roughly 1em even when the loaded face has no glyph for
            // them — using 0.56em here under-measures CJK by ~44%.
            if let Some((kind, new_idx)) = consume_cluster(&chars, idx) {
                width += match kind {
                    Cluster::Wide => font_size,
                    Cluster::ZeroWidth => 0.0,
                };
                idx = new_idx;
                continue;
            }

            let glyph = if let Some(cached) = self.glyph_cache.get(&ch) {
                *cached
            } else {
                let glyph = face.glyph_index(ch).map(|id| id.0);
                self.glyph_cache.insert(ch, glyph);
                glyph
            };

            if let Some(glyph_id) = glyph {
                let advance = if let Some(value) = self.advance_cache.get(&glyph_id) {
                    *value
                } else {
                    let value = face.glyph_hor_advance(GlyphId(glyph_id)).unwrap_or(0);
                    self.advance_cache.insert(glyph_id, value);
                    value
                };
                width += advance as f32 * scale;
            } else if is_cjk_wide_char(ch) {
                width += font_size;
            } else {
                width += fallback;
            }
            idx += 1;
        }

        Some(width.max(0.0))
    }
}

