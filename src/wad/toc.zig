pub const LatestHeader = Header.v3;
pub const LatestEntry = Entry.v3_4;

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
    pub const v1 = packed struct {
        hash: u64,
        offset: u32,
        compressed_len: u32,
        decompressed_len: u32,
        entry_type: EntryType,
        pad: u28 = 0,
    };

    pub const v2 = packed struct {
        hash: u64,
        offset: u32,
        compressed_len: u32,
        decompressed_len: u32,
        entry_type: EntryType,
        subchunk_len: u4,
        duplicate: u8,
        subchunk_index: u16,
    };

    pub const v3 = packed struct {
        hash: u64,
        offset: u32,
        compressed_len: u32,
        decompressed_len: u32,
        entry_type: EntryType,
        subchunk_len: u4,
        duplicate: u8,
        subchunk_index: u16,
        checksum: u64,
    };

    pub const v3_3 = packed struct {
        hash: u64,
        offset: u32,
        compressed_len: u32,
        decompressed_len: u32,
        entry_type: EntryType,
        subchunk_len: u4,
        duplicate: u8,
        subchunk_index: u16,
        checksum: u64,
    };

    pub const v3_4 = packed struct {
        hash: u64,
        offset: u32,
        compressed_len: u32,
        decompressed_len: u32,
        entry_type: EntryType,
        subchunk_len: u4,
        duplicate: u8,
        subchunk_index: u16,
        checksum: u64,
    };
};
