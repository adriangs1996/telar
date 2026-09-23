/// Functions with more parameters need `// codestyle: allow(maximum-parameter-count)`.
pub const maximum_parameters = 5;

pub const Rule = enum {
    invalid_syntax,
    maximum_parameter_count,
    single_line_function_signature,
    trailing_parameter_comma,
    braced_if_branch,
    ordinary_struct_declaration,
    type_file_name,
    namespace_file_name,
    generic_constructor,
    generic_file,
    generic_import,
    dedicated_layout_file,
    receiver_name,
    inline_import,
};
