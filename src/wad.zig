const std = @import("std");
const compress = @import("compress.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const header = @import("./wad/header.zig");

const HeaderV3_4 = extern struct {
    const Version = extern struct {
        magic: [2]u8,
        major: u8,
        minor: u8,
    };

    version: Version,
    ecdsa_signature: [256]u8,
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

const EntryV3_4 = packed struct {
    hash: u64,
    offset: u32,
    compressed_len: u32,
    decompressed_len: u32,
    entry_type: EntryType,
    subchunk_len: u4,
    subchunk: u24,
    checksum: u64,
};

pub fn Iterator(comptime ReaderType: type, comptime SeekableStreamType: type) type {
    return struct {
        allocator: Allocator,

        reader: ReaderType,
        seekable_stream: SeekableStreamType,

        entries_len: u32,
        index: u32 = 0,

        zstd: compress.zstd.Decompressor(ReaderType),

        pub const Entry = struct {
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,

            decompressor: union(enum) {
                none: ReaderType,
                zstd: compress.zstd.Decompressor(ReaderType).Reader,
            },
        };

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.zstd.deinit();
        }

        pub fn next(self: *Self) !?Entry {
            if (self.entries_len > self.index) {
                defer self.index += 1;

                try self.seekable_stream.seekTo(@sizeOf(HeaderV3_4) + @sizeOf(EntryV3_4) * self.index);
                const entry: EntryV3_4 = try self.reader.readStruct(EntryV3_4); // add little endian
                const gb = 1024 * 1024 * 1024;

                assert(4 * gb > entry.compressed_len);
                assert(4 * gb > entry.decompressed_len);
                assert(4 * gb > entry.offset);

                try self.seekable_stream.seekTo(entry.offset);

                if (entry.entry_type == .zstd or entry.entry_type == .zstd_multi) {
                    self.zstd.reset();
                }

                return .{
                    .hash = entry.hash,
                    .compressed_len = entry.compressed_len,
                    .decompressed_len = entry.decompressed_len,
                    .decompressor = switch (entry.entry_type) {
                        .raw => .{ .none = self.reader },
                        .link => @panic("link"),
                        .gzip => @panic("gzip"),
                        .zstd, .zstd_multi => .{ .zstd = self.zstd.reader() },
                    },
                };
            }
            return null;
        }
    };
}

pub const IteratorError = error{
    Corrupted,
    InvalidVersion,
    OutOfMemory,
    Unexpected,
};

pub fn iterator(allocator: Allocator, reader: anytype, seekable_steam: anytype, window_buffer: []u8) IteratorError!Iterator(@TypeOf(reader), @TypeOf(seekable_steam)) {
    const head: HeaderV3_4 = reader.readStruct(HeaderV3_4) catch return error.Corrupted; // add little endian and not nice that we just catching

    if (!mem.eql(u8, &head.version.magic, "RW")) return error.Corrupted;
    if (head.version.major != 3) return error.InvalidVersion;
    if (head.version.minor != 4) return error.InvalidVersion;

    return .{
        .allocator = allocator,
        .reader = reader,
        .seekable_stream = seekable_steam,
        .entries_len = head.entries_len,
        .zstd = try compress.zstd.decompressor(allocator, reader, .{ .window_buffer = window_buffer }),
    };
}
