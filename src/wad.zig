const std = @import("std");

const fs = std.fs;
const io = std.io;
const print = std.debug.print;

const Version = extern struct {
    magic: [2]u8,
    major: u8,
    minor: u8,

    fn latest() Version {
        return .{ .magic = [_]u8{ 'R', 'W' }, .major = 3, .minor = 3 };
    }
};

const HeaderV3 = extern struct {
    version: Version,
    signature: [16]u8,
    signature_unused: [240]u8,
    checksum: [8]u8,
    entries_count: u32,
};

const EntryV3 = packed struct {
    hash: u64,
    offset: u32,
    size: u32,
    size_compressed: u32,
    type: u4,
    subchunk_count: u4,
    is_duplicate: u8,
    subchunk_index: u16,
    checksum_old: u64,
};

const File = std.fs.File;

pub const WADFile = struct {
    file: File,

    pub const OpenError = error{
        InvalidVersion,
    };

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

pub fn openFile(path: []const u8) !WADFile {
    const file = try fs.cwd().openFile(path, .{});

    var buffer_reader = io.bufferedReader(file.reader());
    const reader = buffer_reader.reader();

    const header = try reader.readStruct(HeaderV3);
    const version = header.version;

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    return .{ .file = file };
}
