//! The FFI returns upstream capture names and UTF-8 byte ranges, never colors.
use std::{
    borrow::Cow,
    ffi::{CStr, c_char},
    sync::{
        OnceLock,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::Duration,
};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

// Matches `syntaxhl.limits.source_bytes`, which holds telar's largest review patch.
const MAX_SOURCE: usize = 256 * 1024;
const DEADLINE: Duration = Duration::from_millis(100);
const CAPTURES: &[&CStr] = &[
    c"variable",
    c"keyword",
    c"string",
    c"string.escape",
    c"string.special",
    c"number",
    c"float",
    c"boolean",
    c"comment",
    c"constant",
    c"constant.builtin",
    c"function",
    c"function.builtin",
    c"function.method",
    c"method",
    c"constructor",
    c"type",
    c"type.builtin",
    c"variable.parameter",
    c"parameter",
    c"property",
    c"variable.member",
    c"module",
    c"namespace",
    c"operator",
    c"punctuation",
    c"punctuation.bracket",
    c"punctuation.delimiter",
    c"tag",
    c"attribute",
    c"character",
    c"conditional",
    c"repeat",
    c"exception",
    c"include",
    c"preproc",
    c"storageclass",
    c"variable.builtin",
];

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Span {
    pub start: u32,
    pub end: u32,
    pub capture: *const c_char,
}

#[repr(C)]
pub struct Request {
    pub language: *const c_char,
    pub source: *const u8,
    pub source_len: usize,
    pub spans: *mut Span,
    pub capacity: usize,
    pub count: usize,
}

#[repr(u32)]
#[derive(Debug, PartialEq)]
enum Status {
    Ok,
    Invalid,
    Unsupported,
    Limit,
    Cancelled,
    Internal,
}

const LANGUAGES: &[&str] = &[
    "zig",
    "ruby",
    "python",
    "javascript",
    "typescript",
    "tsx",
    "json",
    "rust",
    "bash",
    "go",
    "c_sharp",
    "java",
    "kotlin",
    "swift",
    "c",
    "cpp",
    "objc",
];

struct Configurations {
    entries: [OnceLock<Result<HighlightConfiguration, Status>>; LANGUAGES.len()],
}

impl Configurations {
    const fn new() -> Self {
        Self {
            entries: [const { OnceLock::new() }; LANGUAGES.len()],
        }
    }

    fn get(&self, language: &str) -> Result<&HighlightConfiguration, Status> {
        let index = LANGUAGES
            .iter()
            .position(|name| *name == language)
            .ok_or(Status::Unsupported)?;
        self.entries[index]
            .get_or_init(|| compile_configuration(language))
            .as_ref()
            .map_err(|_| Status::Internal)
    }
}

fn configuration(language: &str) -> Result<&'static HighlightConfiguration, Status> {
    static CONFIGS: Configurations = Configurations::new();
    CONFIGS.get(language)
}

fn compile_configuration(language: &str) -> Result<HighlightConfiguration, Status> {
    let (grammar, highlights, injections, locals) = match language {
        // The upstream Lua predicates also use valid regex syntax. @spell is an
        // editor directive that would override the comment capture here.
        "zig" => (
            tree_sitter_zig::LANGUAGE,
            Cow::Owned(
                tree_sitter_zig::HIGHLIGHTS_QUERY
                    .replace("#lua-match?", "#match?")
                    .replace(" @spell", ""),
            ),
            tree_sitter_zig::INJECTIONS_QUERY,
            "",
        ),
        "ruby" => (
            tree_sitter_ruby::LANGUAGE,
            Cow::Borrowed(tree_sitter_ruby::HIGHLIGHTS_QUERY),
            "",
            tree_sitter_ruby::LOCALS_QUERY,
        ),
        "python" => (
            tree_sitter_python::LANGUAGE,
            Cow::Borrowed(tree_sitter_python::HIGHLIGHTS_QUERY),
            "",
            "",
        ),
        "javascript" => (
            tree_sitter_javascript::LANGUAGE,
            Cow::Owned(format!(
                "{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_javascript::JSX_HIGHLIGHT_QUERY
            )),
            tree_sitter_javascript::INJECTIONS_QUERY,
            tree_sitter_javascript::LOCALS_QUERY,
        ),
        "typescript" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT,
            Cow::Owned(format!(
                "{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_typescript::HIGHLIGHTS_QUERY
            )),
            tree_sitter_javascript::INJECTIONS_QUERY,
            tree_sitter_typescript::LOCALS_QUERY,
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX,
            Cow::Owned(format!(
                "{}\n{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_typescript::HIGHLIGHTS_QUERY,
                tree_sitter_javascript::JSX_HIGHLIGHT_QUERY
            )),
            tree_sitter_javascript::INJECTIONS_QUERY,
            tree_sitter_typescript::LOCALS_QUERY,
        ),
        "json" => (
            tree_sitter_json::LANGUAGE,
            Cow::Borrowed(tree_sitter_json::HIGHLIGHTS_QUERY),
            "",
            "",
        ),
        "rust" => (
            tree_sitter_rust::LANGUAGE,
            Cow::Borrowed(tree_sitter_rust::HIGHLIGHTS_QUERY),
            tree_sitter_rust::INJECTIONS_QUERY,
            "",
        ),
        "bash" => (
            tree_sitter_bash::LANGUAGE,
            Cow::Borrowed(tree_sitter_bash::HIGHLIGHT_QUERY),
            "",
            "",
        ),
        "go" => (
            tree_sitter_go::LANGUAGE,
            Cow::Borrowed(tree_sitter_go::HIGHLIGHTS_QUERY),
            "",
            "",
        ),
        "c_sharp" => (
            tree_sitter_c_sharp::LANGUAGE,
            Cow::Borrowed(tree_sitter_c_sharp::HIGHLIGHTS_QUERY),
            "",
            "",
        ),
        "java" => (
            tree_sitter_java::LANGUAGE,
            Cow::Borrowed(tree_sitter_java::HIGHLIGHTS_QUERY),
            "",
            "",
        ),
        "kotlin" => (
            tree_sitter_kotlin_sg::LANGUAGE,
            Cow::Borrowed(tree_sitter_kotlin_sg::HIGHLIGHTS_QUERY),
            "",
            "",
        ),
        "swift" => (
            tree_sitter_swift::LANGUAGE,
            Cow::Owned(tree_sitter_swift::HIGHLIGHTS_QUERY.replace(" @spell", "")),
            tree_sitter_swift::INJECTIONS_QUERY,
            tree_sitter_swift::LOCALS_QUERY,
        ),
        "c" => (
            tree_sitter_c::LANGUAGE,
            Cow::Borrowed(tree_sitter_c::HIGHLIGHT_QUERY),
            "",
            "",
        ),
        "cpp" => (
            tree_sitter_cpp::LANGUAGE,
            Cow::Owned(format!(
                "{}\n{}",
                tree_sitter_c::HIGHLIGHT_QUERY,
                tree_sitter_cpp::HIGHLIGHT_QUERY
            )),
            "",
            "",
        ),
        "objc" => (
            tree_sitter_objc::LANGUAGE,
            Cow::Owned(format!(
                "{}\n{}",
                tree_sitter_c::HIGHLIGHT_QUERY,
                tree_sitter_objc::HIGHLIGHTS_QUERY
            )),
            tree_sitter_objc::INJECTIONS_QUERY,
            tree_sitter_objc::LOCALS_QUERY,
        ),
        _ => return Err(Status::Unsupported),
    };
    let mut config =
        HighlightConfiguration::new(grammar.into(), language, &highlights, injections, locals)
            .map_err(|_| Status::Internal)?;
    // Unknown editor predicates must not silently become unconditional matches.
    // Objective-C's has-ancestor? rule is currently skipped.
    for pattern in 0..config.query.pattern_count() {
        if !config.query.general_predicates(pattern).is_empty() {
            config.query.disable_pattern(pattern);
        }
    }
    let names: Vec<&str> = CAPTURES.iter().map(|s| s.to_str().unwrap()).collect();
    config.configure(&names);
    Ok(config)
}

fn highlight(language: &str, source: &[u8], output: &mut [Span]) -> Result<usize, Status> {
    if source.len() > MAX_SOURCE || std::str::from_utf8(source).is_err() {
        return Err(Status::Invalid);
    }
    let config = configuration(language)?;
    let cancelled = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        let (done, completion) = mpsc::channel();
        let cancel = &cancelled;
        scope.spawn(move || {
            if completion.recv_timeout(DEADLINE).is_err() {
                cancel.store(1, Ordering::Relaxed);
            }
        });
        let result = (|| {
            let mut highlighter = Highlighter::new();
            let events = highlighter
                .highlight(config, source, Some(&cancelled), |name| {
                    configuration(name).ok()
                })
                .map_err(|_| Status::Cancelled)?;
            let mut stack = Vec::new();
            let mut count = 0;
            for event in events {
                match event.map_err(|_| Status::Cancelled)? {
                    HighlightEvent::HighlightStart(role) => {
                        if stack.len() >= 128 {
                            return Err(Status::Limit);
                        }
                        stack.push(role.0);
                    }
                    HighlightEvent::HighlightEnd => {
                        stack.pop();
                    }
                    HighlightEvent::Source { start, end } => {
                        if start == end {
                            continue;
                        }
                        let capture = stack
                            .last()
                            .and_then(|&index| CAPTURES.get(index))
                            .unwrap_or(&c"variable")
                            .as_ptr();
                        if count > 0
                            && output[count - 1].end as usize == start
                            && output[count - 1].capture == capture
                        {
                            output[count - 1].end = end as u32;
                        } else {
                            if count == output.len() {
                                return Err(Status::Limit);
                            }
                            output[count] = Span {
                                start: start as u32,
                                end: end as u32,
                                capture,
                            };
                            count += 1;
                        }
                    }
                }
            }
            Ok(count)
        })();
        let _ = done.send(());
        result
    })
}

/// Compiles one language's immutable queries once, before a source-job deadline.
/// Example: `unsafe { telar_syntax_prepare(c"python".as_ptr()) };`
///
/// # Safety
/// `language` must point to a valid NUL-terminated string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn telar_syntax_prepare(language: *const c_char) -> u32 {
    if language.is_null() {
        return Status::Invalid as u32;
    }
    let result = std::panic::catch_unwind(|| {
        let language = unsafe { CStr::from_ptr(language) }
            .to_str()
            .map_err(|_| Status::Invalid)?;
        configuration(language).map(|_| ())
    });
    match result {
        Ok(Ok(())) => Status::Ok as u32,
        Ok(Err(status)) => status as u32,
        Err(_) => Status::Internal as u32,
    }
}

/// # Safety
/// The caller lends valid, nonoverlapping source/output slices for this call.
/// `language` is NUL-terminated. No input pointer is retained; capture pointers
/// refer to immutable library literals and remain valid for the process lifetime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn telar_syntax_highlight(request: *mut Request) -> u32 {
    if request.is_null() {
        return Status::Invalid as u32;
    }
    let request = unsafe { &mut *request };
    request.count = 0;
    if request.language.is_null()
        || request.source.is_null()
        || request.spans.is_null()
        || request.source_len > MAX_SOURCE
        || request.capacity > MAX_SOURCE
    {
        return Status::Invalid as u32;
    }
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let language = unsafe { CStr::from_ptr(request.language) }
            .to_str()
            .map_err(|_| Status::Invalid)?;
        let source = unsafe { std::slice::from_raw_parts(request.source, request.source_len) };
        let output = unsafe { std::slice::from_raw_parts_mut(request.spans, request.capacity) };
        highlight(language, source, output)
    }));
    match result {
        Ok(Ok(count)) => {
            request.count = count;
            Status::Ok as u32
        }
        Ok(Err(status)) => status as u32,
        Err(_) => Status::Internal as u32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configuration_warming_is_per_language_and_shared_between_threads() {
        let cache = Configurations::new();
        assert!(matches!(cache.get("unknown"), Err(Status::Unsupported)));
        assert!(cache.entries.iter().all(|entry| entry.get().is_none()));
        let python = cache.get("python").unwrap();
        assert_eq!(python.language_name, "python");
        assert!(std::ptr::eq(python, cache.get("python").unwrap()));
        for (name, entry) in LANGUAGES.iter().zip(&cache.entries) {
            assert_eq!(entry.get().is_some(), *name == "python", "{name}");
        }
        std::thread::scope(|scope| {
            let workers: Vec<_> = (0..4)
                .map(|_| scope.spawn(|| cache.get("go").unwrap()))
                .collect();
            let go = cache.get("go").unwrap();
            for worker in workers {
                assert!(std::ptr::eq(go, worker.join().unwrap()));
            }
        });
        for (name, entry) in LANGUAGES.iter().zip(&cache.entries) {
            assert_eq!(
                entry.get().is_some(),
                matches!(*name, "python" | "go"),
                "{name}"
            );
        }
    }

    #[test]
    fn prepare_ffi_rejects_invalid_and_unsupported_languages() {
        assert_eq!(
            unsafe { telar_syntax_prepare(std::ptr::null()) },
            Status::Invalid as u32
        );
        assert_eq!(
            unsafe { telar_syntax_prepare(c"unknown".as_ptr()) },
            Status::Unsupported as u32
        );
        assert_eq!(
            unsafe { telar_syntax_prepare(c"\xff".as_ptr()) },
            Status::Invalid as u32
        );
        assert_eq!(
            unsafe { telar_syntax_prepare(c"python".as_ptr()) },
            Status::Ok as u32
        );
        assert_eq!(
            unsafe { telar_syntax_prepare(c"python".as_ptr()) },
            Status::Ok as u32
        );
    }

    fn spans(language: &str, source: &str) -> Vec<(String, String)> {
        let mut output = vec![
            Span {
                start: 0,
                end: 0,
                capture: std::ptr::null()
            };
            source.len()
        ];
        let count = highlight(language, source.as_bytes(), &mut output).unwrap();
        output[..count]
            .iter()
            .map(|s| {
                (
                    source[s.start as usize..s.end as usize].to_owned(),
                    unsafe { CStr::from_ptr(s.capture) }
                        .to_str()
                        .unwrap()
                        .to_owned(),
                )
            })
            .collect()
    }
    #[test]
    fn upstream_grammars_compile_and_emit_captures() {
        for (language, source) in [
            ("zig", "fn run(ctx: *anyopaque) void { _ = ctx; }"),
            ("ruby", "def run(x)\n x + 2\nend"),
            ("python", "def run(x):\n return f'{x}'"),
            ("javascript", "const r = /ab+/g;"),
            ("typescript", "interface User { name: string }"),
            ("tsx", "const el = <div title='x'/>;"),
            ("json", "{\"x\": true}"),
            ("rust", "fn main() { let x = 1; }"),
            ("bash", "echo \"$HOME\""),
        ] {
            let result = spans(language, source);
            assert!(
                result.iter().any(|(_, capture)| capture != "variable"),
                "{language}: {result:?}"
            );
            assert_eq!(
                result.iter().map(|(text, _)| text.len()).sum::<usize>(),
                source.len()
            );
        }
    }
    #[test]
    fn zig_parameters_and_functions_come_from_upstream_queries() {
        let result = spans("zig", "fn run(context: *anyopaque) void { _ = context; }");
        assert!(
            result
                .iter()
                .any(|(text, role)| text == "run" && role.starts_with("function")),
            "{result:?}"
        );
        assert!(
            result
                .iter()
                .any(|(text, role)| text == "context" && role.contains("parameter")),
            "{result:?}"
        );
    }
    #[test]
    fn comments_keep_their_capture() {
        let result = spans("zig", "const x = 42; // comment\n");
        assert!(
            result
                .iter()
                .any(|(text, role)| text.contains("// comment") && role.starts_with("comment")),
            "{result:?}"
        );
    }
    #[test]
    fn language_constructs_and_unicode_use_grammar_captures() {
        for (language, source, needle, expected) in [
            ("ruby", "text = <<~DOC\n  café\nDOC\n", "café", "string"),
            ("python", "text = '''first\nsecond'''\n", "second", "string"),
            ("javascript", "const pattern = /ab+/g;", "ab+", "string"),
            ("tsx", "const el = <div title='x'/>;", "div", "tag"),
            (
                "typescript",
                "/* first\nsecond */\nconst x = 1;",
                "second",
                "comment",
            ),
        ] {
            let result = spans(language, source);
            assert!(
                result
                    .iter()
                    .any(|(text, role)| text.contains(needle) && role.starts_with(expected)),
                "{language}: {result:?}"
            );
            assert_eq!(
                result
                    .iter()
                    .map(|(text, _)| text.as_str())
                    .collect::<String>(),
                source
            );
        }
    }
    #[test]
    fn added_languages_emit_keywords_strings_numbers_and_comments() {
        for (language, source, keyword) in [
            (
                "go",
                "package main\nfunc run() string { value := 42; _ = value; return \"hello\" } // comment\n",
                "package",
            ),
            (
                "c_sharp",
                "class Review { string Run() { int value = 42; return \"hello\"; } } // comment\n",
                "class",
            ),
            (
                "java",
                "class Review { String run() { int value = 42; return \"hello\"; } } // comment\n",
                "class",
            ),
            (
                "kotlin",
                "fun run(): String { val value = 42; return \"hello\" } // comment\n",
                "fun",
            ),
            (
                "swift",
                "func run() -> String { let value = 42; return \"hello\" } // comment\n",
                "func",
            ),
            (
                "c",
                "const char *run(void) { int value = 42; return \"hello\"; } // comment\n",
                "return",
            ),
            (
                "cpp",
                "template<typename T> const char *run(T input) { int value = 42; return \"hello\"; } // comment\n",
                "return",
            ),
            (
                "objc",
                "@implementation Review\n- (id)run { int value = 42; return @\"hello\"; }\n@end // comment\n",
                "@implementation",
            ),
        ] {
            let result = spans(language, source);
            for (needle, expected) in [
                (keyword, "keyword"),
                ("hello", "string"),
                ("42", "number"),
                ("// comment", "comment"),
            ] {
                assert!(
                    result
                        .iter()
                        .any(|(text, role)| text.contains(needle) && role.starts_with(expected)),
                    "{language} {needle}: {result:?}"
                );
            }
            assert_eq!(
                result
                    .iter()
                    .map(|(text, _)| text.as_str())
                    .collect::<String>(),
                source
            );
        }
    }
    #[test]
    fn objective_c_unsupported_editor_predicate_cannot_recolor_all_identifiers() {
        let result = spans("objc", "int run(int value) { return value; }");
        assert!(
            result
                .iter()
                .any(|(text, role)| text.contains("value") && role == "variable"),
            "{result:?}"
        );
    }
    #[test]
    fn limits_invalid_utf8_unknown_language_and_ffi_null_are_rejected() {
        let mut output = [];
        assert_eq!(
            highlight("unknown", b"x", &mut output),
            Err(Status::Unsupported)
        );
        assert_eq!(highlight("zig", &[255], &mut output), Err(Status::Invalid));
        assert_eq!(
            highlight("zig", b"const x = 1;", &mut output),
            Err(Status::Limit)
        );
        assert_eq!(
            unsafe { telar_syntax_highlight(std::ptr::null_mut()) },
            Status::Invalid as u32
        );
    }
}
