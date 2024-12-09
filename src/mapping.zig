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
    pub const View = if (is_windows) []u8 else []align(std.mem.page_size) u8;

    handle: if (is_windows) Handle else void,
    view: View,

    pub fn unmap(self: MappedFile) void {
        if (is_windows) {
            windows.CloseHandle(self.handle);
            windows.UnmapViewOfFile(self.view.ptr);
        } else {
            posix.munmap(self.view);
        }
    }
};

pub const MapFileError = error{
    InvalidSize,
    AccessDenied,
    IsDir,
    SystemResources,
    SharingViolation,
    LockedMemoryLimitExceeded,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoSpaceLeft,
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

/// Call unmap after use.
pub fn mapFile(file: fs.File, flags: MapFlags) MapFileError!MappedFile {
    if (is_windows) {
        return mapFileW(file, flags);
    }

    const size = flags.size orelse file.getEndPos() catch |err| switch (err) {
        error.Unseekable => unreachable,
        else => |e| return e,
    };

    var prot: u32 = 0;
    if (flags.isRead()) prot |= posix.PROT.READ;
    if (flags.isWrite()) prot |= posix.PROT.WRITE;

    if (flags.isRead() and size == 0) return error.InvalidSize;

    return .{
        .handle = {}, // getting error when executing mmap on dirs
        .view = posix.mmap(null, size, prot, .{ .TYPE = if (flags.isWrite()) .SHARED else .PRIVATE }, file.handle, 0) catch |err| return switch (err) {
            error.OutOfMemory => error.SystemResources,
            error.MemoryMappingNotSupported => error.IsDir, // well, not sure tbh
            error.PermissionDenied => error.AccessDenied, // idk why zig called it this way
            else => |e| e,
        },
    };
}

/// Call unmap after use.
pub fn mapFileW(file: fs.File, flags: MapFlags) MapFileError!MappedFile {
    const size = flags.size orelse file.getEndPos() catch |err| switch (err) {
        error.Unseekable => unreachable,
        else => |e| return e,
    };

    if (flags.isRead() and size == 0) return error.InvalidSize;

    const handle = windows.CreateFileMappingA(file.handle, null, if (flags.isWrite()) @as(u32, windows.PAGE_READWRITE) else @as(u32, windows.PAGE_READONLY), 0, @intCast(size), null) catch |err| switch (err) {
        error.FileNotFound => unreachable, // not naming mapping
        error.PathAlreadyExists => unreachable, // not naming mapping
        else => |e| return e,
    }; // todo: not cast and add higher size
    const view = try windows.MapViewOfFile(handle, (if (flags.isRead()) @as(u32, windows.FILE_MAP_READ) else 0) | (if (flags.isWrite()) @as(u32, windows.FILE_MAP_WRITE) else 0), 0, 0, size);

    return .{
        .handle = handle,
        .view = view[0..size],
    };
}
