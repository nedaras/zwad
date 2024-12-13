const std = @import("std");
const assert = std.debug.assert;

var prefix: ?[]const u8 = null;

pub fn init(name: []const u8) void {
    assert(prefix == null);
    prefix = name;
}

pub fn println(comptime fmt: []const u8, args: anytype) void {
    assert(prefix != null);

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());

    bw.writer().writeAll(prefix.?) catch return;
    bw.writer().print(": " ++ fmt ++ "\n", args) catch return;

    bw.flush() catch return;
}
