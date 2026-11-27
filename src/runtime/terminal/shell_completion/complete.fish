# What fish would complete at the end of a line, run by `fish -c` with the line as $argv[1]
# and `rc` as $argv[2] when the user's own configuration is read. The line is data: `complete
# -C` parses it as fish would on Tab and writes each match with its description after a tab.
#
# Without the configuration fish knows no completion directory: the ones it ships and the
# system's own are named here, not the user's.
if test "$argv[2]" != rc
    set -g fish_complete_path $__fish_sysconf_dir/completions $__fish_data_dir/vendor_completions.d $__fish_data_dir/completions
end
complete -C -- $argv[1]
