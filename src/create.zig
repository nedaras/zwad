const std = @import("std");
const wad = @import("wad.zig");
const io = std.io;
const fs = std.fs;
const Options = @import("cli.zig").Options;

pub fn create(options: Options, files: []const []const u8) !void {
    const stdout = io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    const file = try fs.cwd().createFile(options.file.?, .{}); // add fs to handled or sum
    defer file.close();

    const header = wad.output.Header.init();

    try writer.writeStruct(header);
    try bw.flush();
    _ = files;
}
