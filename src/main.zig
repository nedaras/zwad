const std = @import("std");
const wad = @import("wad.zig");

const print = std.debug.print;

pub fn main() !void {
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    print("COOL\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    _ = allocator;

    var file = try std.fs.cwd().openFile("Aatrox.wad.client", .{});
    defer file.close();

    var buffer_reader = std.io.bufferedReader(file.reader());
    _ = buffer_reader;
}
