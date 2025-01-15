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
// and sucendly we do no know what can be subchunked for what i know now .tex files are subchunkuble cuz of bitoffsetss
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

    var entries = try std.ArrayList(ouput.Entry).initCapacity(allocator, files.len);
    defer entries.deinit();

    var offsets = std.AutoHashMap(u64, u32).init(allocator);
    defer offsets.deinit();

    try offsets.ensureTotalCapacity(@intCast(files.len));

    const header_len = @sizeOf(ouput.Header) + @sizeOf(ouput.Entry) * files.len;

    var header_checksum = xxhash.XxHash64.init(0);
    for (files) |sub_path| {
        const file = try fs.cwd().openFile(sub_path, .{});
        defer file.close();

        const decompressed_size: u32 = @intCast(try file.getEndPos());

        zstd_stream.setFrameSize(decompressed_size);

        var hash = xxhash.XxHash3(64).init();

        var compressed_size: u32 = 0;
        while (true) {
            const amt = try file.read(&read_buffer);
            if (amt == 0) break;

            hash.update(read_buffer[0..amt]);
            compressed_size += @intCast(try zstd_stream.write(read_buffer[0..amt]));
        }

        const checksum = hash.final(); // we need to checksum compressed data

        var entry = ouput.Entry.init(.{
            .path = sub_path,
            .compressed_size = compressed_size,
            .decompressed_size = decompressed_size,
            .type = .zstd,
            .checksum = 0, // set this to valid checksum
        });

        if (offsets.get(checksum)) |offset| {
            entry.setOffset(offset);
            //entry.setDuplicate(); // nu such thing in latest entries
            block.items.len -= compressed_size;
        } else {
            const offset: u32 = @intCast(header_len + block.items.len - compressed_size);

            offsets.putAssumeCapacity(checksum, offset);
            entry.setOffset(offset);

            if (compressed_size >= decompressed_size) blk: {
                if (decompressed_size == 0) {
                    entry.setType(.raw);
                    break :blk;
                }
                file.seekTo(0) catch break :blk;

                entry.setType(.raw);
                entry.setCompressedSize(decompressed_size);

                block.items.len -= compressed_size;

                var unread_bytes = decompressed_size;
                while (unread_bytes != 0) {
                    const len = @min(read_buffer.len, unread_bytes);
                    try file.reader().readNoEof(read_buffer[0..len]);

                    try block.appendSlice(read_buffer[0..len]);
                    unread_bytes -= @intCast(len);
                }
            }
        }

        header_checksum.update(mem.asBytes(&entry));
        entries.appendAssumeCapacity(entry);
    }

    // todo: check what is faster sorting paths before hand or sorting entries
    std.sort.block(ouput.Entry, entries.items, {}, struct {
        fn inner(_: void, a: ouput.Entry, b: ouput.Entry) bool {
            return a.raw_entry.hash < b.raw_entry.hash;
        }
    }.inner);

    if (entries.items.len != files.len) {
        if (true) {
            @panic("update checksum");
        }
        const sub: u32 = @intCast(files.len - entries.items.len);
        for (entries.items) |*entry| {
            entry.raw_entry.offset -= sub;
        }
    }

    try writer.writeStruct(ouput.Header.init(.{
        .checksum = header_checksum.final(),
        .entries_len = @intCast(entries.items.len),
    }));

    try writer.writeAll(mem.sliceAsBytes(entries.items));
    try writer.writeAll(block.items);

    _ = options;
}
