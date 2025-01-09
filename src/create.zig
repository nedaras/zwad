const std = @import("std");
const wad = @import("wad.zig");
const compress = @import("compress.zig");
const io = std.io;
const fs = std.fs;
const math = std.math;
const Options = @import("cli.zig").Options;
const assert = std.debug.assert;

pub fn create(allocator: std.mem.Allocator, options: Options, files: []const []const u8) !void {
    const stdout = io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    var block = std.ArrayList(u8).init(allocator);
    defer block.deinit();

    //std.compress.gzip.compressor(undefined, .{});
    for (files) |sub_path| {
        const stat = try fs.cwd().statFile(sub_path);
        assert(std.math.maxInt(u32) >= stat.size);
        const file_size = @as(u32, @intCast(stat.size));
        _ = file_size;

        // we can put in the decompressor file size
        // and then like stream to it

    }

    _ = writer;
    _ = options;

    try bw.flush();
}
