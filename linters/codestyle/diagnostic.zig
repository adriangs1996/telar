pub const Rule = enum {
    invalid_syntax,
    maximum_parameter_count,
    single_line_function_signature,
    trailing_parameter_comma,
    braced_if_branch,
};

pub const Violation = struct {
    rule: Rule,
    line: usize,
    column: usize,
    detail: usize = 0,
};
