const std = @import("std");
const wad = @import("wad.zig");

const print = std.debug.print;

pub fn main() !void {
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    while (try wad_file.next()) |entry| {
        print("hash: {}, size: {}, offset: {}\n", .{ entry.hash, entry.size, entry.offset });
    }

    print("sizeof WADFile: {}\n", .{@sizeOf(wad.WADFile)}); // damm this shi is large, bad we need a ptr to a buffer
    print("COOL {}\n", .{wad_file.header.entries_count});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    _ = allocator;
}
