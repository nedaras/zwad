const std = @import("std");
const wad = @import("wad.zig");
const io = std.io;
const fs = std.fs;
const math = std.math;
const Options = @import("cli.zig").Options;
const assert = std.debug.assert;

pub fn create(allocator: std.mem.Allocator, options: Options, files: []const []const u8) !void {
    const stdout = io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    var estimate_block_size: usize = 0;
    for (files) |file| {
        // we should start to think about 32bit programs
        const stat = try fs.cwd().statFile(file);
        assert(wad.max_file_size >= stat.size);
        assert(wad.max_file_size * 2 >= estimate_block_size + stat.size);
        estimate_block_size += stat.size;
    }

    _ = allocator;
    _ = writer;
    _ = options;

    try bw.flush();
}
