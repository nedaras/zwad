const std = @import("std");
const errors = @import("./errors.zig");
const mapping = @import("./mapping.zig");
const fs = std.fs;
const File = fs.File;
const Dir = fs.Dir;
const Map = mapping.MappedFile;

pub const HandleError = error{
    Usage, // bad usage
    Fatal, // unrecoverable error
    Outdated, // need to update zwad
    Exit, // handled
    OutOfMemory,
    Unexpected,
};

pub fn handle(v: anytype) @typeInfo(@TypeOf(v)).ErrorUnion.payload {
    if (@typeInfo(@TypeOf(v)).ErrorUnion.error_set != HandleError) @compileError("handle expects to have HandleError!T union");
    return v catch |err| {
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
    };
}

pub const Mapping = struct {
    file: File,
    map: Map,

    view: []u8,

    pub fn init(file: File, m: Map) Mapping {
        return .{
            .file = file,
            .map = m,
            .view = m.view,
        };
    }

    pub fn deinit(self: Mapping) void {
        self.map.unmap();
        self.file.close();
    }
};

pub const MapFlags = struct {
    mode: File.OpenMode = .read_only,
    size: ?usize = null,

    lock: File.Lock = .none,
    lock_nonblocking: bool = false,

    allow_ctty: bool = false,
};

pub fn map(dir: Dir, sub_path: []const u8, flags: MapFlags) HandleError!Mapping {
    const open_flags = File.OpenFlags{
        .mode = flags.mode,
        .lock = flags.lock,
        .lock_nonblocking = flags.lock_nonblocking,
        .allow_ctty = flags.allow_ctty,
    };

    const file = dir.openFile(sub_path, open_flags) catch |err| {
        std.debug.print("zwad: {s}: Cannot open: {s}\n", .{ sub_path, errors.stringify(err) });
        return if (err == error.Unexpected) error.Unexpected else error.Fatal;
    };

    const file_map = mapping.mapFile(file, .{ .mode = flags.mode, .size = flags.size }) catch |err| {
        std.debug.print("zwad: {s}: Cannot map: {s}\n", .{ sub_path, errors.stringify(err) });
        return if (err == error.Unexpected) error.Unexpected else error.Fatal;
    };

    return Mapping.init(file, file_map);
}
