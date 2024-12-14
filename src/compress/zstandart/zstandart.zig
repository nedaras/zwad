const std = @import("std");
const zstd = @import("external.zig");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

pub const ZSTDError = @import("ZSTDError.zig").ZSTDError;
pub const UnexpectedError = error{Unexpected};

pub const DecompressStream = zstd.ZSTD_DStream;
pub const InBuffer = zstd.ZSTD_inBuffer;
pub const OutBuffer = zstd.ZSTD_outBuffer;

pub const DecompressError = error{Unexpected};

pub const MAX_FRAME_HEADER_BYTES = 18; // magicNumber(4) + frameHeaderMax(14);
pub const MIN_FRAME_HEADER_BYTES = 6; // magicNumber(4) + frameHeaderMin(2);

pub const MAX_HEADER_BYTES = MAX_FRAME_HEADER_BYTES + 3; // magicNumber(4) + frameHeaderMax(14) + blockHeader(3);
pub const MIN_HEADER_BYTES = MIN_FRAME_HEADER_BYTES + 3; // magicNumber(4) + frameHeaderMin(2) + blockHeader(3);

pub const ZSTD_CONTENTSIZE_UNKNOWN = @as(usize, 0) -% 1;

pub fn decompress(compressed: []const u8, dist: []u8) DecompressError!void {
    const res = zstd.ZSTD_decompress(dist.ptr, dist.len, compressed.ptr, compressed.len);
    switch (getErrorCode(res)) {
        .NO_ERROR => {},
        else => |err| return unexpectedError(err),
    }
}

pub const DecompressStreamError = error{
    NoSpaceLeft,
    MalformedFrame,
    MalformedBlock,
    Unexpected,
};

pub fn decompressStream(stream: *DecompressStream, in: *InBuffer, out: *OutBuffer) DecompressStreamError!usize {
    const res = zstd.ZSTD_decompressStream(stream, out, in);
    return switch (getErrorCode(res)) {
        .NO_ERROR => res,
        .PREFIX_UNKNOWN => error.MalformedFrame,
        .CORRUPTION_DETECTED => error.MalformedBlock,
        .DST_SIZE_TOO_SMALL => error.NoSpaceLeft,
        else => |err| unexpectedError(err),
    };
}

pub const GetFrameContentSizeError = error{
    SizeUnknown,
    BufferTooSmall,
    Unexpected,
};

pub fn getFrameContentSize(buf: []const u8) !usize {
    const res = zstd.ZSTD_getFrameContentSize(buf.ptr, buf.len);
    return switch (getErrorCode(res)) {
        .NO_ERROR => res,
        .GENERIC => error.SizeUnknown,
        else => |err| if (@intFromEnum(err) == 2) return error.BufferTooSmall else unexpectedError(err),
    };
}

fn alloc(ptr: *anyopaque, size: usize) callconv(.C) ?*anyopaque { // todo: remove run time safety
    const allocator: *Allocator = @ptrCast(@alignCast(ptr));

    const header = @sizeOf(usize);
    const alignment = @alignOf(std.c.max_align_t);

    const block = allocator.alignedAlloc(u8, alignment, size + header) catch return null;
    block[0..header].* = @bitCast(size);

    return block.ptr + header;
}

fn free(ptr: *anyopaque, mem: ?*anyopaque) callconv(.C) void {
    const allocator: *Allocator = @ptrCast(@alignCast(ptr));
    const mem_ptr = mem orelse return;

    const header = @sizeOf(usize);
    const alignment = @alignOf(std.c.max_align_t);

    // this is unsafe if zstd allocs data not using our allocator and frees it using ours
    const block_ptr: *anyopaque = @ptrFromInt(@intFromPtr(mem_ptr) - header);
    const block: [*]align(alignment) u8 = @ptrCast(@alignCast(block_ptr));

    const size: usize = @bitCast(block[0..header].*);
    allocator.free(block[0 .. size + header]);
}

pub const InitDecompressStreamError = error{
    OutOfMemory,
    Unexpected,
};

var stored_allocator: Allocator = undefined;
pub fn initDecompressStream(allocator: Allocator) InitDecompressStreamError!*DecompressStream {
    if (allocator.vtable == std.heap.c_allocator.vtable) {
        return zstd.ZSTD_createDStream() orelse return error.OutOfMemory;
    }

    stored_allocator = allocator;
    return zstd.ZSTD_createDStream_advanced(.{
        .customAlloc = &alloc,
        .customFree = &free,
        .@"opaque" = &stored_allocator,
    }) orelse return error.OutOfMemory;
}

pub fn deinitDecompressStream(stream: *DecompressStream) void {
    const res = zstd.ZSTD_freeDStream(stream);
    return switch (getErrorCode(res)) {
        .NO_ERROR => {},
        else => |err| {
            unexpectedError(err) catch unreachable;
        },
    };
}

pub fn getErrorCode(code: usize) ZSTDError {
    return if (zstd.ZSTD_isError(code) == windows.FALSE) ZSTDError.NO_ERROR else @enumFromInt(0 -% code);
}

pub fn unexpectedError(err: ZSTDError) UnexpectedError {
    if (std.posix.unexpected_error_tracing) {
        const code = 0 -% @as(usize, @intCast(@intFromEnum(err)));

        std.debug.print("error.Unexpected: ZSTD_getErrorCode({d}): {s}\n", .{
            @intFromEnum(err),
            zstd.ZSTD_getErrorName(code),
        });
        std.debug.dumpCurrentStackTrace(@returnAddress());
    }

    return error.Unexpected;
}
