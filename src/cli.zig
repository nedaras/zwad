const std = @import("std");
const cli = @import("cli/options.zig");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const help = @embedFile("cli/help.cli");

pub const Diagnostics = struct {
    allocator: Allocator,
    errors: std.ArrayListUnmanaged(Error) = .{},

    pub const Error = union(enum) {
        unknown_option: struct {
            option: []const u8,
        },
    };

    pub fn deinit(self: *Diagnostics) void {
        self.errors.deinit(self.allocator);
    }
};

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

pub const ParseOptions = struct {
    diagnostics: ?*Diagnostics = null,
};

pub const ParseArgumentsError = error{
    OutOfMemory,
    UnknownOption,
};

pub fn parseArguments(allocator: Allocator, options: ParseOptions) ParseArgumentsError!Arguments {
    var iter = try std.process.argsWithAllocator(allocator);
    errdefer iter.deinit();

    _ = iter.next(); // skip cwd arg

    var args = Arguments{
        .iter = iter,
    };

    while (iter.next()) |arg| {
        if (mem.eql(u8, arg, "-") or mem.eql(u8, arg, "--")) { // ignore empty options
            continue;
        }

        var options_iter = cli.optionIterator(arg);
        while (options_iter.next()) |option| switch (option) {
            .list => args.options.list = true,
            .extract => args.options.extract = true,
            .file => {},
            .hashes => {},
            .unknown => {
                if (options.diagnostics) |diagnostics| {
                    try diagnostics.errors.append(allocator, .{
                        .unknown_option = .{ .option = if (options_iter.index) |i| arg[i - 1 .. i] else arg[2..] },
                    });
                    continue;
                }
                return error.UnknownOption;
            },
        };
    }

    return args;
}
