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

    var read_buffer: [1 << 17]u8 = undefined;
    var window_buffer: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.compressor(allocator, block.writer(), .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    for (files) |sub_path| {
        const stat = try fs.cwd().statFile(sub_path);
        assert(std.math.maxInt(u32) >= stat.size);
        assert(stat.kind != .directory);

        const file_size = @as(u32, @intCast(stat.size));

        const file = try fs.cwd().openFile(sub_path, .{});
        defer file.close();

        zstd_stream.setFrameSize(file_size);
        std.debug.print("file size: {d}\n", .{file_size});

        while (true) {
            const amt = try file.read(&read_buffer);
            if (amt == 0) break;

            const n = try zstd_stream.write(read_buffer[0..amt]);
            _ = n;
        }
    }

    try writer.writeAll(block.items);

    _ = options;

    try bw.flush();
}
