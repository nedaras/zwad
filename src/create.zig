const std = @import("std");
const wad = @import("wad.zig");
const compress = @import("compress.zig");
const xxhash = @import("xxhash.zig");
const io = std.io;
const fs = std.fs;
const math = std.math;
const mem = std.mem;
const ouput = wad.output;
const Allocator = mem.Allocator;
const Options = @import("cli.zig").Options;
const assert = std.debug.assert;

// wtf are subchunks?
// subchunks are an file that has .subchunk at the end
// and cuz of that its bad so we should just ignore subchunks and someone using our abi should only create subchunks
// cuz firstly if we do not know the file name how can we know what subchunk it has? cuz files can be renamed, but .subchunk toc will not chnage
//   * tough we could bake in like hash 0 would store the subchunks hash or smth
// and sucendly we do no know what can be subchunked for what i know now .tex files are subchunkuble cuz of bitmaps
// we just need to hope that legue will accept our zstd_multi converted to zstd only and make an abi that would allow to add subchunks
pub fn create(allocator: Allocator, options: Options, files: []const []const u8) !void {
    const stdout = io.getStdOut();
    const writer = stdout.writer();

    if (files.len == 0) {
        return;
    }

    var block = std.ArrayList(u8).init(allocator);
    defer block.deinit();

    var read_buffer: [1 << 17]u8 = undefined;
    var window_buffer: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.compressor(allocator, block.writer(), .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    const toc = @import("wad/toc.zig");

    var entries = try std.ArrayList(toc.Entry.v1).initCapacity(allocator, files.len);
    defer entries.deinit();

    var map = std.AutoHashMap(u64, u32).init(allocator);
    defer map.deinit();

    try map.ensureTotalCapacity(@intCast(files.len));

    for (files) |sub_path| {
        const file = try fs.cwd().openFile(sub_path, .{});
        defer file.close();

        const file_size: u32 = @intCast(try file.getEndPos());

        zstd_stream.setFrameSize(file_size);

        var hash = xxhash.XxHash3(64).init();

        var compressed_size: u32 = 0;
        while (true) {
            const amt = try file.read(&read_buffer);
            if (amt == 0) break;

            hash.update(read_buffer[0..amt]);
            compressed_size += @intCast(try zstd_stream.write(read_buffer[0..amt]));
        }

        const subchunk = hash.final();
        var offset: u32 = undefined;

        var entry_type: wad.EntryType = .zstd;
        if (map.get(subchunk)) |off| {
            offset = off;
            block.items.len -= compressed_size;
        } else {
            const header_len = @sizeOf(toc.Version) + @sizeOf(toc.Header.v1) + @sizeOf(toc.Entry.v1) * files.len;
            offset = @intCast(header_len + block.items.len - compressed_size);
            map.putAssumeCapacity(subchunk, offset);

            if (compressed_size > file_size) blk: {
                file.seekTo(0) catch break :blk;

                entry_type = .raw;
                block.items.len -= compressed_size;

                var unread_bytes = file_size;
                while (unread_bytes != 0) {
                    const len = @min(read_buffer.len, unread_bytes);
                    try file.reader().readNoEof(read_buffer[0..len]);

                    try block.appendSlice(read_buffer[0..len]);
                    unread_bytes -= @intCast(len);
                }
            }
        }

        entries.appendAssumeCapacity(toc.Entry.v1{
            .hash = xxhash.XxHash64.hash(0, sub_path),
            .entry_type = entry_type,
            .compressed_size = compressed_size,
            .decompressed_size = file_size,
            .offset = offset,
        });
    }

    // todo: check what is faster sorting paths before hand or sorting entries
    std.sort.block(toc.Entry.v1, entries.items, {}, struct {
        fn inner(_: void, a: toc.Entry.v1, b: toc.Entry.v1) bool {
            return a.hash < b.hash;
        }
    }.inner);

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

    try writer.writeAll(mem.sliceAsBytes(entries.items));
    try writer.writeAll(block.items);

    _ = options;
}
