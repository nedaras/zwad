const std = @import("std");
const errors = @import("errors.zig");
const handled = @import("handled.zig");
const assert = std.debug.assert;
const HandleError = handled.HandleError;

var prefix: ?[]const u8 = null;

pub fn init(name: []const u8) void {
    assert(prefix == null);
    prefix = name;
}

pub fn println(comptime fmt: []const u8, args: anytype) void {
    assert(prefix != null);

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var bw = std.io.BufferedWriter(256, std.fs.File.Writer){
        .unbuffered_writer = std.io.getStdOut().writer(),
    };

    bw.writer().writeAll(prefix.?) catch return;
    bw.writer().print(": " ++ fmt ++ "\n", args) catch return;

    bw.flush() catch return;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    assert(prefix != null);

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var bw = std.io.BufferedWriter(256, std.fs.File.Writer){
        .unbuffered_writer = std.io.getStdOut().writer(),
    };

    bw.writer().writeAll(prefix.?) catch return;
    bw.writer().print(": " ++ fmt, args) catch return;

    bw.flush() catch return;
}

pub fn errprint(err: errors.Error, comptime fmt: []const u8, args: anytype) HandleError {
    assert(prefix != null);
    const e = handled.fatal(err);

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var bw = std.io.BufferedWriter(256, std.fs.File.Writer){
        .unbuffered_writer = std.io.getStdOut().writer(),
    };

    bw.writer().writeAll(prefix.?) catch return e;
    bw.writer().print(": " ++ fmt, args) catch return e;
    bw.writer().print(": {s}", .{errors.stringify(err)}) catch return e;

    bw.flush() catch return e;
    return e;
}

pub inline fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    println(fmt, args);
    return error.Fatal;
}

pub inline fn unexpected(comptime fmt: []const u8, args: anytype) error{Unexpected} {
    println(fmt, args);
    return error.Unexpected;
}
