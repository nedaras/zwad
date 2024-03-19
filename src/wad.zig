const std = @import("std");

const fs = std.fs;
const io = std.io;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

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
    size: u32,
    size_compressed: u32,
    type: u4,
    subchunk_count: u4,
    is_duplicate: u8,
    subchunk_index: u16,
    checksum_old: u64,
};

const File = fs.File;
const Reader = io.BufferedReader(4096, File.Reader); // mb we can get that usize some diffrent way

pub const WADFile = struct {
    file: File,
    buffer_reader: Reader,
    header: HeaderV3,

    entry_index: u32 = 0,

    pub const OpenError = error{
        InvalidVersion,
    };

    pub fn next(self: *WADFile) !?EntryV3 {
        if (self.entry_index >= self.header.entries_count) return undefined;

        self.entry_index += 1;

        // is reader like a ptr or struct?
        // it is soo i guess it better to have reader class
        const reader = self.buffer_reader.reader();
        return try reader.readStruct(EntryV3);
    }

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

// we need an allocator
pub fn openFile(path: []const u8) !WADFile {
    const file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    errdefer file.close();

    var buffer_reader = io.bufferedReader(file.reader()); // allocate on heap
    const reader = buffer_reader.reader();

    const version = try reader.readStruct(Version);

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    const header = try reader.readStruct(HeaderV3);
    return .{
        .file = file,
        .buffer_reader = buffer_reader,
        .header = header,
    };
}
