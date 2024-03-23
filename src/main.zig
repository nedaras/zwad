const std = @import("std");
const wad = @import("wad.zig");
const PathThree = @import("PathThree.zig");

const fs = std.fs;
const fmt = std.fmt;
const print = std.debug.print;

pub fn createDirs(path: []const u8) !void {
    var i: usize = path.len - 1;
    var dir = path;

    while (i >= 1) : (i -= 1) {
        if (path[i] == '/') {
            dir = path[0 .. i + 1];
            break;
        }
    }

    i = 0;
    while (i < dir.len) : (i += 1) {
        if (path[i] == '/') {
            fs.cwd().makeDir(path[0..i]) catch |e| {
                if (e == error.PathAlreadyExists) {
                    //print("{}\n", .{e});
                } else {
                    return e;
                }
            };
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // c_allocatpr cuz were like allocating bilion things in there
    var hashes = try wad.importHashes(std.heap.c_allocator, "hashes.txt");
    defer hashes.deinit();

    try wad.extractWAD(allocator, "Aatrox.wad.client", "out/", hashes);
}
