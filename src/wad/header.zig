const std = @import("std");
const toc = @import("toc.zig");
const version = @import("version.zig");
const Version = version.Version;

pub const Entry = struct {
    hash: u64,
    compressed_len: u32,
    decompressed_len: u32,

    type: toc.EntryType,

    offset: u32,
};

pub fn HeaderIterator(comptime ReaderType: type) type {
    return struct {
        pub const Error = error{ InvalidFile, EndOfStream } || ReaderType.Error;

        reader: ReaderType,
        ver: Version,

        entries_len: u32,
        index: u32,

        prev_hash: u64 = 0,

        const Self = @This();

        pub fn next(self: *Self) Error!?Entry {
            if (self.index == self.entries_len) return null;

            const gb = 1024 * 1024 * 1024;
            const entry: Entry = switch (self.ver) {
                .v1 => blk: {
                    const entry = try self.reader.readStruct(toc.Entry.v1);
                    break :blk .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .type = entry.entry_type,
                        .offset = entry.offset,
                    };
                },
                .v2 => blk: {
                    const entry = try self.reader.readStruct(toc.Entry.v2);
                    break :blk .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .type = entry.entry_type,
                        .offset = entry.offset,
                    };
                },
                .v3 => blk: {
                    const entry = try self.reader.readStruct(toc.Entry.v3);
                    break :blk .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .type = entry.entry_type,
                        .offset = entry.offset,
                    };
                },
                .v3_3 => blk: {
                    const entry = try self.reader.readStruct(toc.Entry.v3_3);
                    break :blk .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .type = entry.entry_type,
                        .offset = entry.offset,
                    };
                },
                .v3_4 => blk: {
                    const entry = try self.reader.readStruct(toc.Entry.v3_4);
                    break :blk .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .type = entry.entry_type,
                        .offset = entry.offset,
                    };
                },
            };

            if (self.prev_hash > entry.hash) {
                return error.InvalidFile;
            }

            if (entry.decompressed_len > 4 * gb) return error.InvalidFile;
            if (entry.compressed_len > 4 * gb) return error.InvalidFile;
            if (entry.offset > 4 * gb) return error.InvalidFile;

            self.index += 1;
            self.prev_hash = entry.hash;

            return entry;
        }

        pub fn bytesRead(self: Self) u32 {
            return version.sizeOfHeader(self.ver) + version.sizeOfEntry(self.ver) * self.index;
        }
    };
}

pub fn headerIterator(reader: anytype) !HeaderIterator(@TypeOf(reader)) {
    const ver = try getVersion(reader);

    const entries_len = switch (ver) {
        .v1 => (try reader.readStruct(toc.Header.v1)).entries_len,
        .v2 => (try reader.readStruct(toc.Header.v2)).entries_len,
        .v3, .v3_3, .v3_4 => (try reader.readStruct(toc.Header.v3)).entries_len,
    };

    return .{
        .reader = reader,
        .ver = ver,
        .entries_len = entries_len,
        .index = 0,
    };
}

fn getVersion(reader: anytype) !Version {
    const ver: toc.Version = try reader.readStruct(toc.Version);
    if (ver.magic[0] != 'R' or ver.magic[1] != 'W') return error.InvalidFile;

    return switch (ver.major) { // i dont rly know what versions valid what not
        1 => if (ver.minor != 0) return error.UnknownVersion else .v1,
        2 => if (ver.minor != 0) return error.UnknownVersion else .v2,
        3 => return switch (ver.minor) {
            0 => .v3,
            3 => .v3_3,
            4 => .v3_4,
            else => return error.UnknownVersion,
        },
        else => return error.UnknownVersion,
    };
}
