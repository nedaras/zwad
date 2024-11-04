const std = @import("std");
const xxhash = @import("xxhash.zig");
const assert = std.debug.assert;

pub fn main() !void {
    const input = "hello world";
    var hash3 = xxhash.XxHash3(128).init(0);
    hash3.update(input);

    std.debug.print("hash: {x}\n", .{hash3.final()});
    std.debug.print("hash: {x}\n", .{xxhash.XxHash64.hash(0, "no")});

    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
