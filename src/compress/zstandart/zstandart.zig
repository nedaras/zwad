const std = @import("std");
const zstd = @import("external.zig");
const windows = std.os.windows;

pub const ZSTDError = @import("ZSTDError.zig").ZSTDError;
pub const UnexpectedError = error{Unexpected};

pub const DecompressError = error{Unexpected};

pub fn decompress(buf: []u8, compressed: []const u8) DecompressError!void {
    const res = zstd.ZSTD_decompress(buf.ptr, buf.len, compressed.ptr, compressed.len);
    switch (getErrorCode(res)) {
        .NO_ERROR => {},
        else => |err| return unexpectedError(err),
    }
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
