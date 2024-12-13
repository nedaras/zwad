const std = @import("std");
const toc = @import("./toc.zig");

pub const IterError = error{
    UnknownVersion,
    InvalidFile,
    EndOfStream,
};

pub fn HeaderIterator(comptime ReaderType: type) type {
    return struct {
        pub const Entry = struct {
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,
        };

        reader: ReaderType,
        entries_len: u32,

        const self = @This();

        pub fn next() (ReaderType.Error || IterError)!void {}
    };
}

pub fn headerIterator(reader: anytype) !HeaderIterator(@TypeOf(reader)) {
    const version: toc.Version = try reader.readStruct(toc.Version);

    if (version.magic[0] != 'R' or version.magic[1] != 'W') return error.InvalidFile;
    errdefer std.debug.print("{d}:{d}\n", .{ version.major, version.minor }); // for debug

    var entries_len: u32 = undefined;
    switch (version.major) { // i dont rly know what versions valid what not
        1 => {
            if (version.minor != 0) return error.UnknownVersion;
            entries_len = (try reader.readStruct(toc.Header.v1)).entries_len;
        },
        2 => {
            if (version.minor != 0) return error.UnknownVersion;
            entries_len = (try reader.readStruct(toc.Header.v2)).entries_len;
        },
        3 => switch (version.minor) {
            0, 3, 4 => {
                entries_len = (try reader.readStruct(toc.Header.v3)).entries_len;
            },
            else => return error.UnknownVersion,
        },
        else => return error.UnknownVersion,
    }

    return .{
        .reader = reader,
        .entries_len = entries_len,
    };
}
