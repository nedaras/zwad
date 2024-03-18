const std = @import("std");

const Version = extern struct { magic: [2]u8, major: u8, minor: u8 };

const HeaderV3 = extern struct { version: Version, signature: [16]u8, signature_unused: [240]u8, checksum: [8]u8, desc_count: u32 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    _ = allocator;

    var file = try std.fs.cwd().openFile("Aatrox.wad.client", .{});
    defer file.close();

    var buffer_reader = std.io.bufferedReader(file.reader());
    const reader = buffer_reader.reader();

    const header = try reader.readStruct(HeaderV3);

    std.debug.print("magic = {s}\n", .{header.version.magic});
    std.debug.print("major = {}\n", .{header.version.major});
    std.debug.print("minor = {}\n", .{header.version.minor});
    std.debug.print("count = {}\n", .{header.desc_count});
}
