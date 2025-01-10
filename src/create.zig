const std = @import("std");
const wad = @import("wad.zig");
const compress = @import("compress.zig");
const xxhash = @import("xxhash.zig");
const io = std.io;
const fs = std.fs;
const math = std.math;
const Options = @import("cli.zig").Options;
const assert = std.debug.assert;

fn ascXxhashed64(seed: u64) fn (void, []const u8, []const u8) bool {
    return struct {
        pub fn inner(_: void, a: []const u8, b: []const u8) bool {
            return xxhash.XxHash64.hash(seed, a) < xxhash.XxHash64.hash(seed, b);
        }
    }.inner;
}

// todo: make like set([]const u8) of files
// todo: optimize for duplicates ignoring
// todo: ignore duplicate file paths
pub fn create(allocator: std.mem.Allocator, options: Options, files: []const []const u8) !void {
    const stdout = io.getStdOut();
    const writer = stdout.writer();

    if (files.len == 0) {
        return;
    }

    for (files) |f| {
        std.debug.print("{s}\n", .{f});
    }

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
        const file = try fs.cwd().openFile(sub_path, .{});
        defer file.close();

        const file_size: u32 = @intCast(try file.getEndPos());

        zstd_stream.setFrameSize(file_size);

        var compressed_size: u32 = 0;
        while (true) {
            const amt = try file.read(&read_buffer);
            if (amt == 0) break;

            compressed_size += @intCast(try zstd_stream.write(read_buffer[0..amt]));
        }
        const offset: u32 = @intCast(@sizeOf(toc.Version) + @sizeOf(toc.Header.v1) + @sizeOf(toc.Entry.v1) * entries.items.len + block.items.len);
        try entries.append(toc.Entry.v1{
            .hash = xxhash.XxHash64.hash(0, sub_path),
            .entry_type = .zstd,
            .compressed_len = compressed_size,
            .decompressed_len = file_size,
            .offset = offset,
        });
    }

    if (entries.items.len != files.len) {
        const sub: u32 = @intCast(files.len - entries.items.len);
        for (entries.items) |*entry| {
            entry.offset -= sub;
        }
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

    try writer.writeAll(std.mem.asBytes(block.items));
    try writer.writeAll(block.items);

    _ = options;
}
