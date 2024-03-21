const std = @import("std");

extern fn ZSTD_decompress(dst: *anyopaque, dst_len: usize, src: *const anyopaque, src_len: usize) usize;
extern fn ZSTD_getErrorName(code: usize) [*c]const u8;
extern fn ZSTD_isError(code: usize) bool;

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const Allocator = mem.Allocator;
const File = fs.File;

const Version = extern struct {
    magic: [2]u8,
    major: u8,
    minor: u8,

    fn latest() Version {
        return .{ .magic = [_]u8{ 'R', 'W' }, .major = 3, .minor = 3 };
    }
};

const HeaderV3 = extern struct {
    signature: [16]u8,
    signature_unused: [240]u8,
    checksum: [8]u8,
    entries_count: u32,
};

const EntryV3 = packed struct {
    hash: u64,
    offset: u32,
    size_compressed: u32,
    size_decompressed: u32,
    type: u4,
    subchunk_count: u4,
    is_duplicate: u8,
    subchunk_index: u16,
    checksum_old: u64,
};

pub const WADFile = struct {
    file: File,
    entries_count: u32,

    entry_index: u32 = 0,

    pub const OpenError = error{
        InvalidVersion,
    } || File.OpenError;

    pub const DecompressError = error{
        InvalidEntry,
    } || Allocator.Error || File.ReadError || File.SeekError || File.GetSeekPosError;

    pub fn next(self: *WADFile) !?EntryV3 {
        if (self.entry_index >= self.entries_count) return null;

        self.entry_index += 1;

        // is reader like a ptr or struct?
        // it is soo i guess it better to have reader class
        const reader = self.file.reader();
        return try reader.readStruct(EntryV3);
    }

    pub fn decompressEntry(self: WADFile, entry: EntryV3, allocator: Allocator) DecompressError![]u8 {
        var out = try allocator.alloc(u8, entry.size_decompressed);
        errdefer allocator.free(out);

        var src = try allocator.alloc(u8, entry.size_compressed);
        defer allocator.free(src);

        const pos = try self.file.getPos();
        try self.file.seekTo(entry.offset);

        _ = try self.file.read(src);

        try self.file.seekTo(pos);

        const bytes = ZSTD_decompress(out.ptr, entry.size_decompressed, src.ptr, entry.size_compressed);

        if (ZSTD_isError(bytes)) return WADFile.DecompressError.InvalidEntry;

        return out;
    }

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

pub fn openFile(path: []const u8) !WADFile {
    const file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    errdefer file.close();

    const reader = file.reader(); // we can read ver and head with one sys call

    const version = try reader.readStruct(Version);

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    const header = try reader.readStruct(HeaderV3);

    return .{
        .file = file,
        .entries_count = header.entries_count,
    };
}
