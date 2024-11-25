const win = @import("std").os.windows;
const c = @cImport({
    @cInclude("zstd.h");
});

// we need to add it //https://github.com/facebook/zstd/blob/v1.5.2/lib/decompress/zstd_decompress_internal.h ZSTD_DCtx_s
pub const ZSTD_DStream = opaque {}; // atleast figure out the size

pub const ZSTD_inBuffer = extern struct {
    src: [*]u8,
    size: usize,
    pos: usize,
};

pub const ZSTD_outBuffer = extern struct {
    dst: [*]u8,
    size: usize,
    pos: usize,
};

pub extern fn ZSTD_freeDStream(zds: *ZSTD_DStream) usize;

pub extern fn ZSTD_createDStream() ?*ZSTD_DStream;

pub extern fn ZSTD_initDStream(zds: *ZSTD_DStream) usize;

pub extern fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, compressedSize: usize) callconv(.C) usize;

pub extern fn ZSTD_decompressStream(zds: *ZSTD_DStream, output: *ZSTD_outBuffer, input: *ZSTD_inBuffer) callconv(.C) usize;

pub extern fn ZSTD_isError(code: usize) callconv(.C) win.BOOL;

pub extern fn ZSTD_getErrorName(code: usize) callconv(.C) [*:0]const u8;
