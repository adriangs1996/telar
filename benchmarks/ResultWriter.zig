const std = @import("std");
const Config = @import("Config.zig");
const Case = @import("Case.zig");
const Measurement = @import("Measurement.zig");
const ResultWriter = @This();

writer: *std.Io.Writer,
config: Config,

pub fn write(self: ResultWriter, case: Case, result: Measurement) !void {
    const rate = if (result.median_ns == 0)
        0
    else
        @as(u128, std.time.ns_per_s) * case.work_per_op / result.median_ns;
    if (self.config.json) {
        try self.writer.print(
            "{{\"type\":\"benchmark\",\"name\":\"{s}\",\"iterations\":{d}," ++
                "\"samples\":{d},\"median_ns_per_op\":{d},\"min_ns_per_op\":{d}," ++
                "\"p95_ns_per_op\":{d},\"p99_ns_per_op\":{d}," ++
                "\"work_per_op\":{d},\"work_unit\":\"{s}\"," ++
                "\"work_per_second\":{d},\"payload_bytes_per_op\":{d}," ++
                "\"p99_budget_ns\":{d}}}\n",
            .{
                case.name,
                result.iterations,
                self.config.samples,
                result.median_ns,
                result.minimum_ns,
                result.p95_ns,
                result.p99_ns,
                case.work_per_op,
                case.work_unit,
                rate,
                case.payload_bytes_per_op,
                case.p99_budget_ns,
            },
        );
    } else {
        try self.writer.print("{s}\n  median {d} ns/op, p95 {d} ns/op, p99 {d} ns/op, min {d} ns/op, {d} {s}/s", .{
            case.name,
            result.median_ns,
            result.p95_ns,
            result.p99_ns,
            result.minimum_ns,
            rate,
            case.work_unit,
        });
        if (case.payload_bytes_per_op != 0) {
            try self.writer.print(", payload {d} B/op", .{case.payload_bytes_per_op});
        }
        try self.writer.writeByte('\n');
    }
    if (self.config.enforce and result.p99_ns > case.p99_budget_ns) {
        return error.PerformanceBudgetExceeded;
    }
}
