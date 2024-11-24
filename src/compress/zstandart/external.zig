const win = @import("std").os.windows;
const c = @cImport({
    @cInclude("zstd.h");
});

pub extern fn ZSTD_isError(code: usize) callconv(.C) win.BOOL;

pub extern fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, compressedSize: usize) callconv(.C) usize;

pub extern fn ZSTD_getErrorName(code: usize) callconv(.C) [*:0]const u8;
