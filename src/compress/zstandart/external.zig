const win = @import("std").os.windows;
const c = @cImport({
    @cInclude("zstd.h");
    @cInclude("zstd_decompress_internal.h");
});

pub const ZSTD_seqSymbol = extern struct {
    nextState: u16,
    nbAdditionalBits: u8,
    nbBits: u8,
    baseValue: u32,
};

pub const ZSTD_DStream = c.ZSTD_DCtx;

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

pub extern fn ZSTD_getFrameContentSize(src: [*]const u8, srcSize: usize) usize;

pub extern fn ZSTD_freeDStream(zds: *ZSTD_DStream) usize;

pub extern fn ZSTD_createDStream() ?*ZSTD_DStream;

pub extern fn ZSTD_initDStream(zds: *ZSTD_DStream) usize;

pub extern fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, compressedSize: usize) callconv(.C) usize;

pub extern fn ZSTD_decompressStream(zds: *ZSTD_DStream, output: *ZSTD_outBuffer, input: *ZSTD_inBuffer) callconv(.C) usize;

pub extern fn ZSTD_isError(code: usize) callconv(.C) win.BOOL;

pub extern fn ZSTD_getErrorName(code: usize) callconv(.C) [*:0]const u8;
