pub const LatestHeader = Header.v3;
pub const LatestEntry = Entry.v3;

pub const Version = extern struct {
    magic: [2]u8 = [_]u8{ 'R', 'W' },
    major: u8,
    minor: u8,
};

pub const EntryType = enum(u4) {
    raw,
    link,
    gzip,
    zstd,
    zstd_multi,
};

pub const Header = struct {
    pub const v1 = extern struct {
        entries_offset: u16,
        entries_size: u16,
        entries_len: u32,
    };

    pub const v2 = extern struct {
        ecdsa_signature_len: u8,
        ecdsa_signature: [83]u8,
        checksum: u64 align(1),
        entries_offset: u16,
        entries_size: u16,
        entries_len: u32,
    };

    pub const v3 = extern struct {
        ecdsa_signature: [256]u8,
        checksum: u64 align(1),
        entries_len: u32,
    };
};

pub const Entry = struct {
    pub const v1 = extern struct {
        hash: u64,
        offset: u32,
        compressed_size: u32,
        decompressed_size: u32,
        byte: u8,
        pad: [3]u8 = [_]u8{ 0, 0, 0 },
    };

    pub const v2 = extern struct {
        hash: u64,
        offset: u32,
        compressed_size: u32,
        decompressed_size: u32,
        byte: u8,
        duplicate: bool,
        subchunk_index: u16,
    };

    pub const v3 = extern struct {
        hash: u64,
        offset: u32,
        compressed_size: u32,
        decompressed_size: u32,
        byte: u8,
        duplicate: bool,
        subchunk_index: u16,
        checksum: u64,
    };
};
