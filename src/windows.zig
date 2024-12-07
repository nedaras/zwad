const std = @import("std");
const kernel32 = @import("./windows/kernel32.zig");
const windows = std.os.windows;
const assert = std.debug.assert;

pub usingnamespace windows;

pub const SECTION_MAP_EXECUTE_EXPLICIT = 0x0020;

pub const FILE_MAP_WRITE = windows.SECTION_MAP_WRITE;
pub const FILE_MAP_READ = windows.SECTION_MAP_READ;
pub const FILE_MAP_ALL_ACCESS = windows.SECTION_ALL_ACCESS;

pub const FILE_MAP_EXECUTE = SECTION_MAP_EXECUTE_EXPLICIT;

pub const FILE_MAP_COPY = 0x00000001;

pub const FILE_MAP_RESERVE = 0x80000000;
pub const FILE_MAP_TARGETS_INVALID = 0x40000000;
pub const FILE_MAP_LARGE_PAGES = 0x20000000;

pub const CreateFileMappingAError = error{
    AccessDenied,
    FileNotFound,
    PathAlreadyExists,
    SystemResources,
    SharingViolation,
    NoSpaceLeft,
    Unexpected,
};

pub fn CreateFileMappingA(hFile: windows.HANDLE, LPSECURITY_ATTRIBUTES: ?*anyopaque, flProtect: windows.DWORD, dwMaximumSizeHigh: windows.DWORD, dwMaximumSizeLow: windows.DWORD, lpName: ?windows.LPCSTR) CreateFileMappingAError!windows.HANDLE {
    if (kernel32.CreateFileMappingA(hFile, LPSECURITY_ATTRIBUTES, flProtect, dwMaximumSizeHigh, dwMaximumSizeLow, lpName)) |mapping| {
        return mapping;
    }
    return switch (windows.kernel32.GetLastError()) {
        .ACCESS_DENIED => error.AccessDenied,
        .FILE_NOT_FOUND => error.FileNotFound,
        .ALREADY_EXISTS => error.PathAlreadyExists,
        .BAD_LENGTH => error.NoSpaceLeft,
        .NO_SYSTEM_RESOURCES => error.SystemResources,
        .NOT_ENOUGH_MEMORY => error.SystemResources,
        .SHARING_VIOLATION => error.SharingViolation,
        .INSUFFICIENT_BUFFER => error.NoSpaceLeft,
        .INVALID_HANDLE => unreachable,
        .INVALID_ACCESS => unreachable,
        .INVALID_PARAMETER => unreachable,
        else => |err| windows.unexpectedError(err),
    };
}

pub const MapViewOfFileError = error{
    AccessDenied,
    SystemResources,
    SharingViolation,
    Unexpected,
};

pub fn MapViewOfFile(hFileMappingObject: windows.HANDLE, dwDesiredAccess: windows.DWORD, dwFileOffsetHigh: windows.DWORD, dwFileOffsetLow: windows.DWORD, dwNumberOfBytesToMap: windows.SIZE_T) MapViewOfFileError![*]u8 {
    if (kernel32.MapViewOfFile(hFileMappingObject, dwDesiredAccess, dwFileOffsetHigh, dwFileOffsetLow, dwNumberOfBytesToMap)) |view| {
        return view;
    }
    return switch (windows.kernel32.GetLastError()) {
        .ACCESS_DENIED => error.AccessDenied,
        .NOACCESS => error.AccessDenied,
        .OUTOFMEMORY => error.SystemResources,
        .DISK_FULL => error.SystemResources,
        .SHARING_VIOLATION => error.SharingViolation,
        .NOT_ENOUGH_QUOTA => error.SystemResources,
        .INVALID_HANDLE => unreachable,
        .INVALID_ACCESS => unreachable,
        .INVALID_PARAMETER => unreachable,
        else => |err| windows.unexpectedError(err),
    };
}

pub fn UnmapViewOfFile(lpBaseAddress: windows.LPCVOID) void {
    assert(kernel32.UnmapViewOfFile(lpBaseAddress) == windows.TRUE);
}
