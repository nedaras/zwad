const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const posix = std.posix;
const is_windows = builtin.os.tag == .windows;

pub const Handle = std.posix.fd_t;
pub const File = std.fs.File;

pub const MappedFile = struct {
    handle: if (is_windows) Handle else void,
    view: []u8,

    pub fn unmap(self: MappedFile) void {
        windows.CloseHandle(self.handle);
        windows.UnmapViewOfFile(self.view.ptr);
    }
};

pub const MapFileError = error{
    AccessDenied,
    SystemResources,
    Unseekable,
    Unexpected,
};

// todo: add linux support and add flags
/// Call unmap after use.
pub fn mapFile(file: File) MapFileError!MappedFile {
    if (!is_windows) @compileError("mapFile is not yet implemented for posix");

    const file_len = try file.getEndPos();

    const handle = try windows.CreateFileMappingA(file.handle, null, windows.PAGE_READONLY, 0, 0, null);
    const view = try windows.MapViewOfFile(handle, windows.FILE_MAP_READ, 0, 0, 0);

    return .{
        .handle = handle,
        .view = view[0..file_len],
    };
}
