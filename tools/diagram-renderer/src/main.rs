use mermaid_rs_renderer::{LayoutConfig, Theme};
use serde::Deserialize;
use std::io::{Read, Write};
mod bounded_allocator;

#[global_allocator]
static ALLOCATOR: bounded_allocator::BoundedAllocator = bounded_allocator::BoundedAllocator;

const MAX_INPUT: usize = 320 * 1024;
const MAX_SOURCE: usize = 48 * 1024;
const MAX_SVG: usize = 4 * 1024 * 1024;
const MAX_SIDE: u32 = 4096;
const MAX_PIXELS: u32 = 4 * 1024 * 1024;
const FONT: &[u8] = include_bytes!("../../../src/assets/IBMPlexSans-Regular.ttf");
const BOLD_FONT: &[u8] = include_bytes!("../../../src/assets/IBMPlexSans-SemiBold.ttf");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    source: String,
    scale: f32,
    bg: String,
    fg: String,
    accent: String,
}

#[derive(Debug, PartialEq)]
enum Failure {
    Invalid = 2,
    Unsupported = 3,
    Limit = 4,
}

struct Raster {
    pixels: resvg::tiny_skia::Pixmap,
    logical_width: f32,
    logical_height: f32,
}

fn main() {
    // Parser panic diagnostics can quote source. The protocol exposes only fixed errors.
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(|| {
        apply_limits()?;
        let request = read_request(std::io::stdin().lock())?;
        let raster = render(&request)?;
        write_raster(&raster, std::io::stdout().lock())
    })
    .unwrap_or(Err(Failure::Invalid));
    if let Err(error) = result {
        let message = match error {
            Failure::Invalid => "invalid diagram input",
            Failure::Unsupported => "unsupported diagram feature",
            Failure::Limit => "diagram resource limit",
        };
        eprintln!("{message}");
        std::process::exit(error as i32);
    }
}

fn read_request(reader: impl Read) -> Result<Request, Failure> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_INPUT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::Invalid)?;
    if bytes.len() > MAX_INPUT {
        return Err(Failure::Limit);
    }
    let request: Request = serde_json::from_slice(&bytes).map_err(|_| Failure::Invalid)?;
    if request.source.len() > MAX_SOURCE {
        return Err(Failure::Limit);
    }
    if request.source.trim().is_empty()
        || request.source.contains('\0')
        || !request.scale.is_finite()
        || !(0.5..=4.0).contains(&request.scale)
    {
        return Err(Failure::Invalid);
    }
    for color in [&request.bg, &request.fg, &request.accent] {
        parse_color(color)?;
    }
    Ok(request)
}

fn parse_color(value: &str) -> Result<resvg::tiny_skia::Color, Failure> {
    if value.len() != 7
        || !value.starts_with('#')
        || !value.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
    {
        return Err(Failure::Invalid);
    }
    let rgb = u32::from_str_radix(&value[1..], 16).map_err(|_| Failure::Invalid)?;
    Ok(resvg::tiny_skia::Color::from_rgba8(
        (rgb >> 16) as u8,
        (rgb >> 8) as u8,
        rgb as u8,
        255,
    ))
}

fn render(request: &Request) -> Result<Raster, Failure> {
    // Links and callbacks have no meaning in the raster protocol. Reject them before layout.
    for statement in request.source.split(['\n', ';']) {
        let statement = statement.trim_start();
        if statement.starts_with("click ") || statement.starts_with("click\t") {
            return Err(Failure::Unsupported);
        }
    }
    let parsed = mermaid_rs_renderer::parse_mermaid_strict(&request.source).map_err(|error| {
        if matches!(error, mermaid_rs_renderer::ParseError::UnexpectedToken { ref expected, .. }
            if expected == "unknown or missing Mermaid diagram header")
        {
            Failure::Unsupported
        } else {
            Failure::Invalid
        }
    })?;
    if !parsed.graph.node_links.is_empty()
        || parsed
            .graph
            .c4
            .shapes
            .iter()
            .any(|shape| shape.link.is_some() || shape.sprite.is_some())
        || parsed
            .graph
            .c4
            .boundaries
            .iter()
            .any(|shape| shape.link.is_some() || shape.sprite.is_some())
        || parsed
            .graph
            .c4
            .rels
            .iter()
            .any(|shape| shape.link.is_some() || shape.sprite.is_some())
    {
        return Err(Failure::Unsupported);
    }
    let theme = theme(request);
    let layout_options = LayoutConfig::default();
    let layout = mermaid_rs_renderer::compute_layout(&parsed.graph, &theme, &layout_options);
    let svg = mermaid_rs_renderer::render_svg(&layout, &theme, &layout_options);
    validate_svg(&svg)?;
    let mut options = resvg::usvg::Options {
        font_family: "IBM Plex Sans".into(),
        image_href_resolver: resvg::usvg::ImageHrefResolver {
            resolve_data: Box::new(|_, _, _| None),
            resolve_string: Box::new(|_, _| None),
        },
        ..Default::default()
    };
    options.fontdb_mut().load_font_data(FONT.to_vec());
    options.fontdb_mut().load_font_data(BOLD_FONT.to_vec());
    options.fontdb_mut().set_sans_serif_family("IBM Plex Sans");
    options.fontdb_mut().set_serif_family("IBM Plex Sans");
    options.fontdb_mut().set_monospace_family("IBM Plex Sans");
    let tree = resvg::usvg::Tree::from_str(&svg, &options).map_err(|_| Failure::Invalid)?;
    let logical_width = tree.size().width();
    let logical_height = tree.size().height();
    let (width, height, scale) = dimensions(logical_width, logical_height, request.scale)?;
    let mut pixels = resvg::tiny_skia::Pixmap::new(width, height).ok_or(Failure::Limit)?;
    pixels.fill(parse_color(&request.bg)?);
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale, scale),
        &mut pixels.as_mut(),
    );
    Ok(Raster {
        pixels,
        logical_width,
        logical_height,
    })
}

fn dimensions(width: f32, height: f32, requested: f32) -> Result<(u32, u32, f32), Failure> {
    if !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0 {
        return Err(Failure::Limit);
    }
    let scale = (requested as f64)
        .min(MAX_SIDE as f64 / width as f64)
        .min(MAX_SIDE as f64 / height as f64)
        .min((MAX_PIXELS as f64 / (width as f64 * height as f64)).sqrt());
    let raster_width = (width as f64 * scale).floor().max(1.0) as u32;
    let raster_height = (height as f64 * scale).floor().max(1.0) as u32;
    if raster_width > MAX_SIDE
        || raster_height > MAX_SIDE
        || raster_width as u64 * raster_height as u64 > MAX_PIXELS as u64
    {
        return Err(Failure::Limit);
    }
    Ok((raster_width, raster_height, scale as f32))
}

fn theme(request: &Request) -> Theme {
    let mut theme = Theme::modern();
    theme.font_family = "IBM Plex Sans".into();
    for value in [
        &mut theme.background,
        &mut theme.primary_color,
        &mut theme.secondary_color,
        &mut theme.tertiary_color,
        &mut theme.edge_label_background,
        &mut theme.cluster_background,
        &mut theme.sequence_actor_fill,
        &mut theme.sequence_note_fill,
        &mut theme.sequence_activation_fill,
        &mut theme.git_commit_label_background,
        &mut theme.git_tag_label_background,
    ] {
        *value = request.bg.clone();
    }
    for value in [
        &mut theme.primary_text_color,
        &mut theme.text_color,
        &mut theme.git_commit_label_color,
        &mut theme.git_tag_label_color,
        &mut theme.pie_title_text_color,
        &mut theme.pie_section_text_color,
        &mut theme.pie_legend_text_color,
    ] {
        *value = request.fg.clone();
    }
    for value in [
        &mut theme.primary_border_color,
        &mut theme.line_color,
        &mut theme.cluster_border,
        &mut theme.sequence_actor_border,
        &mut theme.sequence_actor_line,
        &mut theme.sequence_note_border,
        &mut theme.sequence_activation_border,
        &mut theme.git_tag_label_border,
        &mut theme.pie_stroke_color,
        &mut theme.pie_outer_stroke_color,
    ] {
        *value = request.accent.clone();
    }
    theme
}

fn validate_svg(svg: &str) -> Result<(), Failure> {
    if svg.len() > MAX_SVG {
        return Err(Failure::Limit);
    }
    let document = roxmltree::Document::parse(svg).map_err(|_| Failure::Unsupported)?;
    for element in document.descendants().filter(roxmltree::Node::is_element) {
        if matches!(
            element.tag_name().name(),
            "script" | "image" | "foreignObject" | "a" | "font" | "font-face" | "iframe"
        ) {
            return Err(Failure::Unsupported);
        }
        for attribute in element.attributes() {
            let name = attribute.name().to_ascii_lowercase();
            if name.starts_with("on") || name == "href" || name == "src" {
                return Err(Failure::Unsupported);
            }
            validate_css(attribute.value())?;
        }
        if element.tag_name().name() == "style" {
            validate_css(element.text().unwrap_or_default())?;
        }
    }
    Ok(())
}

fn validate_css(value: &str) -> Result<(), Failure> {
    let lower = value.to_ascii_lowercase();
    // CSS escapes and imports can disguise resource URLs; generated SVG needs neither.
    if lower.contains('@')
        || lower.contains('\\')
        || lower.contains("javascript:")
        || lower.contains("expression(")
    {
        return Err(Failure::Unsupported);
    }
    for suffix in lower.split("url(").skip(1) {
        let Some(end) = suffix.find(')') else {
            return Err(Failure::Unsupported);
        };
        let reference = suffix[..end].trim().trim_matches(['\'', '"']);
        if !reference.starts_with('#') || reference.len() <= 1 {
            return Err(Failure::Unsupported);
        }
    }
    Ok(())
}

fn write_raster(raster: &Raster, mut output: impl Write) -> Result<(), Failure> {
    let mut header = [0_u8; 24];
    header[..4].copy_from_slice(b"TLRD");
    header[4..8].copy_from_slice(&raster.pixels.width().to_le_bytes());
    header[8..12].copy_from_slice(&raster.pixels.height().to_le_bytes());
    header[12..16].copy_from_slice(&raster.logical_width.to_le_bytes());
    header[16..20].copy_from_slice(&raster.logical_height.to_le_bytes());
    output
        .write_all(&header)
        .and_then(|_| output.write_all(raster.pixels.data()))
        .map_err(|_| Failure::Invalid)
}

#[cfg(unix)]
fn apply_limits() -> Result<(), Failure> {
    let cpu = libc::rlimit {
        rlim_cur: 5,
        rlim_max: 5,
    };
    let memory = libc::rlimit {
        rlim_cur: 512 * 1024 * 1024,
        rlim_max: 512 * 1024 * 1024,
    };
    // Some macOS versions reject RLIMIT_AS. The Rust heap quota applies on both hosts.
    unsafe {
        if libc::setrlimit(libc::RLIMIT_CPU, &cpu) != 0 {
            return Err(Failure::Limit);
        }
        #[cfg(not(target_os = "macos"))]
        if libc::setrlimit(libc::RLIMIT_AS, &memory) != 0 {
            return Err(Failure::Limit);
        }
        #[cfg(target_os = "macos")]
        let _ = libc::setrlimit(libc::RLIMIT_AS, &memory);
    }
    Ok(())
}

#[cfg(not(unix))]
fn apply_limits() -> Result<(), Failure> {
    Err(Failure::Unsupported)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(source: &str) -> Request {
        Request {
            source: source.into(),
            scale: 1.0,
            bg: "#15202b".into(),
            fg: "#f0f4f8".into(),
            accent: "#65baff".into(),
        }
    }

    #[test]
    fn renders_capture_and_sequence_with_exact_premultiplied_payload() {
        for source in [
            include_str!("../tests/capture.mmd"),
            "sequenceDiagram\nparticipant A as Cliente\nparticipant B as Agente\nA->>B: petición\nB-->>A: respuesta",
        ] {
            let raster = render(&request(source)).unwrap();
            let mut bytes = Vec::new();
            write_raster(&raster, &mut bytes).unwrap();
            assert_eq!(&bytes[..4], b"TLRD");
            assert_eq!(
                bytes.len(),
                24 + raster.pixels.width() as usize * raster.pixels.height() as usize * 4
            );
            assert_eq!(&bytes[20..24], &[0; 4]);
            assert!(
                raster
                    .pixels
                    .data()
                    .chunks_exact(4)
                    .all(|px| px[..3].iter().all(|v| *v <= px[3]))
            );
            assert!(
                raster
                    .pixels
                    .data()
                    .chunks_exact(4)
                    .any(|px| px[..3] != [0x15, 0x20, 0x2b])
            );
        }
    }

    #[test]
    fn limits_dimensions_without_distorting_aspect() {
        for (w, h, scale) in [
            (1e7, 1e7, 4.0),
            (100.0, 100000.0, 2.0),
            (535.0, 1434.0, 4.0),
        ] {
            let (pw, ph, actual) = dimensions(w, h, scale).unwrap();
            assert!(pw <= MAX_SIDE && ph <= MAX_SIDE && pw as u64 * ph as u64 <= MAX_PIXELS as u64);
            assert!((pw as f32 - w * actual).abs() <= 1.01);
            assert!((ph as f32 - h * actual).abs() <= 1.01);
        }
    }

    #[test]
    fn rejects_external_resources_callbacks_and_css_before_raster() {
        assert!(matches!(
            render(&request(
                "flowchart LR\nA-->B\nclick A \"https://example.invalid\""
            )),
            Err(Failure::Unsupported)
        ));
        for svg in [
            "<svg><image href='file:///secret'/></svg>",
            "<svg><script/></svg>",
            "<svg><a href='https://example.invalid'/></svg>",
            "<svg><style>@font-face { src: url(secret) }</style></svg>",
            "<svg onload='x'/>",
            "<svg style='fill: url(file:///secret)'/>",
            "<svg><foreignObject/></svg>",
        ] {
            assert_eq!(validate_svg(svg), Err(Failure::Unsupported));
        }
        assert!(validate_svg("<svg><path marker-end='url(#marker)'/></svg>").is_ok());
    }

    #[test]
    fn validates_decoded_source_input_and_scale_limits() {
        let json = |source: &str, scale: f32| {
            serde_json::json!({"source":source,"scale":scale,"bg":"#ffffff","fg":"#000000","accent":"#123456"}).to_string()
        };
        assert!(read_request(json("flowchart LR\nA-->B", 1.0).as_bytes()).is_ok());
        assert!(matches!(
            read_request(json(&"x".repeat(MAX_SOURCE + 1), 1.0).as_bytes()),
            Err(Failure::Limit)
        ));
        assert!(matches!(
            read_request(vec![b' '; MAX_INPUT + 1].as_slice()),
            Err(Failure::Limit)
        ));
        assert!(matches!(
            read_request(json("x", 4.1).as_bytes()),
            Err(Failure::Invalid)
        ));
        assert!(matches!(
            read_request(json("x\0y", 1.0).as_bytes()),
            Err(Failure::Invalid)
        ));
        assert!(matches!(read_request(&[0xff][..]), Err(Failure::Invalid)));
        assert!(matches!(
            render(&request("notADiagram\nx")),
            Err(Failure::Unsupported)
        ));
    }
}
