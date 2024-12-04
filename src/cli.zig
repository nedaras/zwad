const std = @import("std");
const cli = @import("cli/options.zig");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const help = @embedFile("cli/help.cli");

pub const Arguments = struct {
    iter: std.process.ArgIterator,

    options: struct {
        extract: bool = false,
        list: bool = false,
        file: ?[]const u8 = null,
        hashes: ?[]const u8 = null,
    } = .{},

    files: ?[][]const u8 = null,

    pub fn deinit(self: *Arguments) void {
        self.iter.deinit();
    }
};

pub const ParseArgumentsError = std.process.ArgIterator.InitError || error{
    UnknownArgument,
};

pub fn parseArguments(allocator: Allocator) ParseArgumentsError!Arguments {
    var iter = try std.process.argsWithAllocator(allocator);
    errdefer iter.deinit();

    _ = iter.next(); // skip cwd arg

    var args = Arguments{
        .iter = iter,
    };

    while (iter.next()) |arg| {
        var options = cli.optionIterator(arg);
        while (options.next()) |option| switch (option) {
            .list => args.options.list = true,
            .extract => args.options.extract = true,
            .file => {},
            .hashes => {},
            .unknown => return error.UnknownArgument,
        };
    }

    return args;
}
