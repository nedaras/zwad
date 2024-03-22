const std = @import("std");
const wad = @import("wad.zig");

const fs = std.fs;
const fmt = std.fmt;
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    try wad.importHashes(allocator, "hashes.txt");

    // it would be nice to know should o have like init deinit functions, like idk todo zig way
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    fs.cwd().makeDir("out") catch {
        return;
    };

    while (try wad_file.next()) |entry| {
        const data = try wad_file.decompressEntry(allocator, entry);
        defer allocator.free(data);

        const file_name = try fmt.allocPrint(allocator, "out/{d}", .{entry.hash});
        defer allocator.free(file_name);

        _ = try fs.cwd().writeFile(file_name, data);

        print("name: {s}\n", .{file_name});
    }

    print("sizeof WADFile: {}\n", .{@sizeOf(@TypeOf(wad_file))});
}
