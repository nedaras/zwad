const std = @import("std");

const Version = extern struct {
    magic: [2]u8,
    major: u8,
    minor: u8,
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

// ok we need to learn some zig cuz i think this is bad

pub const WADFile = struct {
    file: std.fs.File,
    buffered_reader: std.io.BufferedReader(4096, std.fs.File.Reader),

    pub const OpenError = error{
        InvalidVersion,
    } || std.fs.File.OpenError;

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

pub fn openFile(path: []const u8) WADFile.OpenError!WADFile {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    return .{ .file = file, .buffered_reader = std.io.bufferedReader(file.reader()) };
}
