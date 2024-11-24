const win = @import("std").os.windows;

pub extern "kernel32" fn CreateFileMappingA(hFile: win.HANDLE, LPSECURITY_ATTRIBUTES: ?*anyopaque, flProtect: win.DWORD, dwMaximumSizeHigh: win.DWORD, dwMaximumSizeLow: win.DWORD, lpName: ?win.LPCSTR) callconv(win.WINAPI) ?win.HANDLE;

pub extern "kernel32" fn MapViewOfFile(hFileMappingObject: win.HANDLE, dwDesiredAccess: win.DWORD, dwFileOffsetHigh: win.DWORD, dwFileOffsetLow: win.DWORD, dwNumberOfBytesToMap: win.SIZE_T) callconv(win.WINAPI) ?[*]u8;

pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: win.LPCVOID) callconv(win.WINAPI) win.BOOL;
