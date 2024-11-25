const std = @import("std");
const zstd = @import("external.zig");
const windows = std.os.windows;

pub const ZSTDError = @import("ZSTDError.zig").ZSTDError;
pub const UnexpectedError = error{Unexpected};

pub const DecompressStream = zstd.ZSTD_DStream;
pub const zstd_in_buf = zstd.ZSTD_inBuffer;
pub const zstd_out_buf = zstd.ZSTD_outBuffer;

pub const DecompressError = error{Unexpected};

pub fn decompress(compressed: []const u8, dist: []u8) DecompressError!void {
    const res = zstd.ZSTD_decompress(dist.ptr, dist.len, compressed.ptr, compressed.len);
    switch (getErrorCode(res)) {
        .NO_ERROR => {},
        else => |err| return unexpectedError(err),
    }
}

pub const DecompressStreamError = error{
    NoSpaceLeft,
    Unexpected,
};

pub fn decompressStream(stream: *DecompressStream, in: *zstd_in_buf, out: *zstd_out_buf) DecompressStreamError!usize {
    const res = zstd.ZSTD_decompressStream(stream, out, in);
    return switch (getErrorCode(res)) {
        .NO_ERROR => res,
        .DST_SIZE_TOO_SMALL => error.NoSpaceLeft,
        else => |err| unexpectedError(err),
    };
}

pub const GetFrameContentSizeError = error{Unexpected};

fn getFrameContentSize(buf: []const u8) !usize {
    const res = zstd.ZSTD_getFrameContentSize(buf.ptr, buf.len);
    return switch (getErrorCode(res)) {
        .NO_ERROR => res,
        else => |err| unexpectedError(err),
    };
}

pub const InitDecompressStreamError = error{Unexpected};

pub fn initDecompressStream() InitDecompressStreamError!*DecompressStream {
    const decompress_steam = zstd.ZSTD_createDStream().?;
    const res = zstd.ZSTD_initDStream(decompress_steam);
    return switch (getErrorCode(res)) {
        .NO_ERROR => decompress_steam,
        else => |err| unexpectedError(err),
    };
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
    const code = 0 -% @as(usize, @intCast(@intFromEnum(err)));

    std.debug.print("error.Unexpected: ZSTD_getErrorCode({d}): {s}\n", .{
        @intFromEnum(err),
        zstd.ZSTD_getErrorName(code),
    });
    std.debug.dumpCurrentStackTrace(@returnAddress());

    return error.Unexpected;
}
