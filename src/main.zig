const std = @import("std");
const wad = @import("wad.zig");

const print = std.debug.print;

pub fn main() !void {
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    while (try wad_file.next()) |entry| {
        print("hash: {}, size: {}, offset: {}\n", .{ entry.hash, entry.size, entry.offset });
    }

    print("sizeof WADFile: {}\n", .{@sizeOf(@TypeOf(wad_file))}); // damm this shi is large, bad we need a ptr to a buffer
    print("COOL {}\n", .{wad_file.header.entries_count});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const BufferReader = std.io.BufferedReader(4096, std.fs.File.Reader);

    var buffer_reader = try allocator.create(BufferReader);
    defer allocator.destroy(buffer_reader);

    buffer_reader.* = std.io.bufferedReader(wad_file.file.reader());

    print("sizeof BufferReader with allocator.create: {}\n", .{@sizeOf(@TypeOf(buffer_reader))});
    // 16 bytes for allocator? that is not cool mb they can be a comptime thing.
    print("sizeof Allocator: {}\n", .{@sizeOf(@TypeOf(allocator))});
}
