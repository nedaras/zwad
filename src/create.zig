const std = @import("std");
const wad = @import("wad.zig");
const compress = @import("compress.zig");
const xxhash = @import("xxhash.zig");
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

    const toc = @import("wad/toc.zig");

    var entries = std.ArrayList(toc.Entry.v1).init(allocator);
    defer entries.deinit();

    for (files) |sub_path| {
        const stat = try fs.cwd().statFile(sub_path);
        assert(std.math.maxInt(u32) >= stat.size);
        assert(stat.kind != .directory);

        const file_size = @as(u32, @intCast(stat.size));

        const file = try fs.cwd().openFile(sub_path, .{});
        defer file.close();

        zstd_stream.setFrameSize(file_size);
        std.debug.print("file size: {d}\n", .{file_size});

        var compressed_size: u32 = 0;
        while (true) {
            const amt = try file.read(&read_buffer);
            if (amt == 0) break;

            compressed_size += @intCast(try zstd_stream.write(read_buffer[0..amt]));
        }

        try entries.append(.{
            .hash = xxhash.XxHash64.hash(0, sub_path),
            .entry_type = .zstd,
            .compressed_len = compressed_size,
            .decompressed_len = file_size,
            .offset = @intCast(block.items.len - compressed_size),
        });
    }

    try writer.writeStruct(toc.Version{
        .major = 1,
        .minor = 0,
    });
    try writer.writeStruct(toc.Header.v1{
        .entries_len = @intCast(entries.items.len),
        .entries_size = @sizeOf(toc.Entry.v1),
        .entries_offset = @sizeOf(toc.Version) + @sizeOf(toc.Header.v1),
    });

    for (entries.items) |*entry| {
        entry.offset += @intCast(@sizeOf(toc.Version) + @sizeOf(toc.Header.v1) + entries.items.len * @sizeOf(toc.Entry.v1));
        try writer.writeStruct(entry.*);
    }

    try writer.writeAll(block.items);

    _ = options;

    try bw.flush();
}
