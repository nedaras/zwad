const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const magic_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "RW\x01", "wad" },
    .{ "RW\x02", "wad" },
    .{ "RW\x03", "wad" },
    .{ "DDS", "dds" },
    .{ "\x33\x22\x11\x00", "skn" },
    .{ "TEX\x00", "tex" },
    .{ "PROP", "bin" },
    .{ "PTCH", "bin" },
    .{ "BKHD", "bnk" },
    .{ "r3d2Mesh", "scb" },
    .{ "r3d2anmd", "anm" },
    .{ "r3d2canm", "anm" },
    .{ "r3d2sklt", "skl" },
    .{ "[ObjectBegin]", "sco" },
});

/// Searches for a file extension inside file's binary data.
pub fn extention(data: []u8) ?[]const u8 {
    assert(data.len >= minLookupBytes());

    // todo: in some future we can make these entries into int64 and just bin search
    for (magic_map.keys()) |key| {
        if (mem.startsWith(u8, data, key)) {
            return magic_map.get(key).?;
        }
    }

    if (std.mem.eql(u8, data[4..8], "\xC3\x4F\xFD\x22")) {
        return "skl";
    }

    return null;
}

pub fn minLookupBytes() comptime_int {
    comptime {
        var n: usize = 0;
        for (magic_map.keys()) |key| {
            n = @max(n, key.len);
        }
        return @max(n, 8); // for skl
    }
}

pub fn maxExtentionBytes() comptime_int {
    comptime {
        var n: usize = 0;
        for (magic_map.values()) |key| {
            n = @max(n, key.len);
        }
        return n;
    }
}
