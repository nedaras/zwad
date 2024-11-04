const std = @import("std");
const xxhash = @import("xxhash.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const assert = std.debug.assert;

const c = @cImport({
    @cInclude("zstd.h");
});

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
    raw,
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

    //var fbr = io.bufferedReader(file.reader());
    const reader = file.reader();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 3);

    var list_in = std.ArrayList(u8).init(allocator); // todo: dont use arraylist as a reusible buffer
    defer list_in.deinit();

    var list_out = std.ArrayList(u8).init(allocator); // todo: dont use arraylist as a reusible buffer
    defer list_out.deinit();

    for (header.entries_len) |_| { // prob its better to mmap file then streaming and seeking it
        const entry = try reader.readStruct(Entry);
        switch (entry.entry_type) {
            .zstd => {
                assert(entry.decompressed_len > entry.compressed_len); // prob can be hit often

                try list_in.ensureTotalCapacity(entry.compressed_len);
                try list_out.ensureTotalCapacity(entry.decompressed_len);

                assert(list_in.capacity >= entry.compressed_len);
                assert(list_out.capacity >= entry.decompressed_len);

                const in = list_in.items.ptr[0..entry.compressed_len];
                const out = list_in.items.ptr[0..entry.decompressed_len];

                const pos = try file.getPos();
                try file.seekTo(entry.offset);

                //std.debug.print("pos: {d}\n", .{pos});

                //std.debug.print("pos: {x}\n", .{pos});
                //std.debug.print("unused: {x}\n", .{fbr.start - fbr.end});
                //try file.seekTo(entry.offset);

                assert(try file.reader().readAll(in) == entry.compressed_len);
                assert(out.len == c.ZSTD_getDecompressedSize(in.ptr, in.len));
                //std.debug.print("pos: {d}, {d}\n", .{in[0..4]});

                std.debug.print("frame: {d}\n", .{find_frame_start(in)});

                //const zstd_len = c.ZSTD_decompress(out.ptr, out.len, src.ptr, src.len); // why its failing????
                //if (c.ZSTD_isError(zstd_len) == 1) {
                //std.debug.print("err: {s}\n", .{c.ZSTD_getErrorName(zstd_len)});
                //} else {
                //std.debug.print("no err\n", .{});
                //}

                try file.seekTo(pos);
            },
            .raw, .gzip, .link, .zstd_multi => |t| {
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}

fn find_frame_start(buf: []const u8) !usize {
    const magic = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    return mem.indexOf(u8, buf, &magic) orelse return error.CouldNotBeFound;
}
