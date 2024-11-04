const std = @import("std");
const xxhash = @import("xxhash.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;

const Header = extern struct {
    const Version = extern struct {
        major: u8,
        minor: u8,
    };

    magic: [2]u8,
    version: Version,
    signature: u128 align(1), // its just all entries checksums hashed
    unknown: [240]u8, // idk what should this be
    checksum: u64 align(1),
    entries_len: u32,
};

const EntryType = enum(u4) {
    raw = 0,
    link,
    gzip,
    zstd,
    zstd_multi,
};

const Entry = packed struct {
    hash: u64,
    offset: u32,
    compressed_len: u32,
    decompressed_len: u32,
    entry_type: EntryType,
    subchunk_len: u4,
    duplicate: u8,
    subchunk: u16,
    checksum: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing; // now try to extract only a file
    const dst = args.next() orelse return error.ArgumentDstDirMissing;
    _ = dst;

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    var fbr = io.bufferedReader(file.reader());
    const reader = fbr.reader();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 3);

    var list = std.ArrayList(u8).init(allocator); // todo: dont use arraylist as a reusible buffer
    defer list.deinit();

    for (header.entries_len) |_| { // prob its better to mmap file then streaming and seeking it
        const entry = try reader.readStruct(Entry);
        switch (entry.entry_type) {
            .zstd => {
                const pos = try file.getPos();
                try file.seekTo(entry.offset);

                try list.ensureTotalCapacity(entry.decompressed_len);
                assert(list.capacity >= entry.decompressed_len);

                const slice = list.items.ptr[0..entry.decompressed_len];

                var window_buf: [1 << 23]u8 = undefined;
                var zstd_stream = zstd.decompressor(file.reader(), .{ .window_buffer = &window_buf }); // zigs implemintation is too slow, and we cant compress

                assert(try zstd_stream.reader().readAll(slice) == entry.decompressed_len);

                try file.seekTo(pos);
            },
            .raw, .gzip, .link, .zstd_multi => |t| {
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}
