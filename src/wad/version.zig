const toc = @import("toc.zig");

pub const Version = enum {
    v1,
    v2,
    v3,
    v3_3,
    v3_4,
};

pub fn sizeOfHeader(version: Version) u32 {
    return switch (version) {
        .v1 => @sizeOf(toc.Version) + @sizeOf(toc.Header.v1),
        .v2 => @sizeOf(toc.Version) + @sizeOf(toc.Header.v2),
        .v3, .v3_3, .v3_4 => @sizeOf(toc.Version) + @sizeOf(toc.Header.v3),
    };
}

pub fn sizeOfEntry(version: Version) u32 {
    return switch (version) {
        .v1 => @sizeOf(toc.Entry.v1),
        .v2 => @sizeOf(toc.Entry.v2),
        .v3 => @sizeOf(toc.Entry.v3),
        .v3_3 => @sizeOf(toc.Entry.v3_3),
        .v3_4 => @sizeOf(toc.Entry.v3_4),
    };
}
