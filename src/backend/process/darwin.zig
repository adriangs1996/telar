pub const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/sysctl.h");
});
