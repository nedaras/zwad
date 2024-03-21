const std = @import("std");
const wad = @import("wad.zig");

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // it would be nice to know should o have like init deinit functions, like idk todo zig way
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    if (try wad_file.next()) |entry| {
        const buffa = try wad_file.decompressEntry(entry, allocator);
        defer allocator.free(buffa);

        _ = try std.fs.cwd().writeFile("out.dds", buffa);
    }

    print("sizeof WADFile: {}\n", .{@sizeOf(@TypeOf(wad_file))});
}
