const std = @import("std");
const wad = @import("wad.zig");
extern fn ZSTD_decompress(dst: *anyopaque, dst_len: usize, src: *const anyopaque, src_len: usize) usize;
extern fn ZSTD_getErrorName(code: usize) [*c]const u8;
extern fn ZSTD_isError(code: usize) bool;

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // it would be nice to know should o have like init deinit functions, like idk todo zig way
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    if (try wad_file.next()) |entry| {
        var buffer = wad_file.getBuffer(entry).init(allocator);
        defer buffer.deinit();

        //const size = ZSTD_decompress(out.ptr, out.len, buffer.ptr, buffer.len);
        //const err = ZSTD_getErrorName(size);

        //print("ZSTD_decompress: {}\n", .{size});
        //print("err: {s}\n", .{err});
        //print("hash: {}, size: {}, b_size: {}\n", .{ entry.hash, entry.size_compressed, buffer.len });
    }

    print("sizeof WADFile: {}\n", .{@sizeOf(@TypeOf(wad_file))});
}
