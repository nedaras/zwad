const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const posix = std.posix;
const fs = std.fs;
const OpenMode = fs.File.OpenMode;
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

pub const MapFlags = struct {
    mode: OpenMode = .read_only,
    size: ?usize = null,

    pub fn isRead(self: MapFlags) bool {
        return self.mode != .write_only;
    }

    pub fn isWrite(self: MapFlags) bool {
        return self.mode != .read_only;
    }
};

// todo: add linux support
/// Call unmap after use.
pub fn mapFile(file: fs.File, flags: MapFlags) MapFileError!MappedFile {
    if (!is_windows) @compileError("mapFile is not yet implemented for posix");

    const size = flags.size orelse try file.getEndPos();

    const handle = try windows.CreateFileMappingA(file.handle, null, if (flags.isWrite()) @as(u32, windows.PAGE_READWRITE) else @as(u32, windows.PAGE_READONLY), 0, @intCast(size), null); // todo: not cast and add higher size
    const view = try windows.MapViewOfFile(handle, (if (flags.isRead()) @as(u32, windows.FILE_MAP_READ) else 0) | (if (flags.isWrite()) @as(u32, windows.FILE_MAP_WRITE) else 0), 0, 0, size);

    return .{
        .handle = handle,
        .view = view[0..size],
    };
}
