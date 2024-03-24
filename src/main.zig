const std = @import("std");
const wad = @import("wad.zig");
const PathThree = @import("PathThree.zig");

const fs = std.fs;
const fmt = std.fmt;
const heap = std.heap;
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // c_allocatpr cuz were like allocating bilion things in there
    //var hashes = try wad.importHashes(heap.c_allocator, "hashes.txt");
    //defer hashes.deinit();

    //try wad.extractWAD(allocator, "Aatrox.wad.client", "out/", hashes);
    try wad.makeWAD(allocator, "out/", "out.wad", "out_hashes.txt");
}
