const std = @import("std");
const compress = @import("compress.zig");
const mem = std.mem;
const assert = std.debug.assert;

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
        reader: ReaderType,
        seekable_stream: SeekableStreamType,

        entries_len: u32,
        index: u32 = 0,

        pub const Entry = struct {
            hash: u64,
            offset: u32,
            compressed_len: u32,
            decompressed_len: u32,
            entry_type: EntryType,

            parent_reader: ReaderType,
            parent_seekable_stream: SeekableStreamType,

            // woud be nice to make c zstd to have a reader
            pub fn decompress(self: Entry, buf: []u8, out: []u8) !void {
                if (self.entry_type != .zstd) return;

                assert(buf.len == self.compressed_len);
                assert(out.len == self.decompressed_len);

                const pos = try self.parent_seekable_stream.getPos();

                try self.parent_seekable_stream.seekTo(self.offset);
                try self.parent_reader.readNoEof(buf);
                try self.parent_seekable_stream.seekTo(pos);

                try compress.zstd.bufDecompress(buf, out);
            }
        };

        const Self = @This();

        pub fn next(self: *Self) !?Entry {
            if (self.entries_len > self.index) {
                defer self.index += 1;

                const entry: EntryV3_4 = try self.reader.readStruct(EntryV3_4); // add little endian
                const gb = 1024 * 1024 * 1024;

                assert(4 * gb > entry.compressed_len);
                assert(4 * gb > entry.decompressed_len);
                assert(4 * gb > entry.offset);

                return .{
                    .hash = entry.hash,
                    .offset = entry.offset,
                    .compressed_len = entry.compressed_len,
                    .decompressed_len = entry.decompressed_len,
                    .entry_type = entry.entry_type,
                    .parent_reader = self.reader,
                    .parent_seekable_stream = self.seekable_stream,
                };
            }
            return null;
        }
    };
}

pub fn iterator(reader: anytype, seekable_steam: anytype) !Iterator(@TypeOf(reader), @TypeOf(seekable_steam)) {
    const header: HeaderV3_4 = try reader.readStruct(HeaderV3_4); // add little endian

    assert(mem.eql(u8, &header.version.magic, "RW")); // ret error
    assert(header.version.major == 3); // add multi version stuff
    assert(header.version.minor == 4); // add multi version stuff

    return .{
        .reader = reader,
        .seekable_stream = seekable_steam,
        .entries_len = header.entries_len,
    };
}
