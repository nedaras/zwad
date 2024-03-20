const std = @import("std");
const wad = @import("wad.zig");

extern fn ZSTD_decompress(dst: [*c]u8, dstCapacity: usize, [*c]const u8, compressedSize: usize) usize;
extern fn ZSTD_getErrorName(code: usize) [*c]const u8;

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // it would be nice to know should o have like init deinit functions, like idk todo zig way
    var wad_file = try wad.openFile("Aatrox.wad.client", allocator);
    defer wad_file.close();

    if (try wad_file.next()) |entry| {
        var buffer = try wad_file.getBuffer(entry);
        defer allocator.free(buffer);

        var out = try allocator.alloc(u8, entry.size);
        defer allocator.free(out);

        // how to wrap errors here
        const size = ZSTD_decompress(out.ptr, out.len, buffer.ptr, buffer.len);
        const err = ZSTD_getErrorName(size);

        print("ZSTD_decompress: {}\n", .{size});
        print("err: {s}\n", .{err});
        print("hash: {}, type: {}, sub_count: {}\n", .{ entry.hash, entry.type, entry.subchunk_count });
    }

    print("sizeof WADFile: {}\n", .{@sizeOf(@TypeOf(wad_file))});
}
