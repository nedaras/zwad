const std = @import("std");

pub const Error = error{
    FileNotFound,
    AccessDenied,
    SharingViolation,
    PipeBusy,
    DeviceBusy,
    NameTooLong,
    InvalidUtf8,
    InvalidWtf8,
    BadPathName,
    NetworkNotFound,
    AntivirusInterference,
    NoDevice,
    SymLinkLoop,
    SystemResources,
    FileTooBig,
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    IsDir,
    Unexpected,
};

pub const HandleError = error{
    Usage, // bad usage
    Fatal, // unrecoverable error
    Outdated, // need to update zwad
    Exit, // handled
    OutOfMemory,
    Unexpected,
};

pub fn stringify(err: Error) [:0]const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.SharingViolation, error.PipeBusy, error.DeviceBusy => "Device or resource busy",
        error.NameTooLong => "File name too long",
        error.InvalidUtf8, error.InvalidWtf8 => "Invalid or incomplete multibyte or wide character",
        error.BadPathName => "Path invalid",
        error.NetworkNotFound => "Network not found",
        error.AntivirusInterference => "Blocked by antivirus",
        error.NoDevice => "No such device or address",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.SystemResources => "Cannot allocate memory",
        error.FileTooBig => "File too large",
        error.SystemFdQuotaExceeded => "System quota exceeded",
        error.ProcessFdQuotaExceeded => "Too many open files",
        error.IsDir => "Is a directory",
        error.Unexpected => "Unknown error",
    };
}

pub fn handle(err: HandleError) noreturn {
    const exit_code: u8 = if (err == error.Fatal or err == error.OutOfMemory or err == error.Unexpected) 1 else 0;
    switch (err) {
        error.Usage => std.debug.print(@embedFile("./cli/messages/usage.cli"), .{}),
        error.Fatal => std.debug.print(@embedFile("./cli/messages/fatal.cli"), .{}),
        error.Outdated => std.debug.print(@embedFile("./cli/messages/fatal.cli"), .{}),
        error.OutOfMemory => std.debug.print(@embedFile("./cli/messages/oof.cli"), .{}),
        error.Unexpected => std.debug.print(@embedFile("./cli/messages/unexpected.cli"), .{}),
        error.Exit => {},
    }
    std.process.exit(exit_code);
}
