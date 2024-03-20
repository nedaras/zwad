const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zstd = b.addStaticLibrary(.{
        .name = "zstd",
        .target = target,
        .optimize = optimize,
    });

    zstd.addIncludePath(.{ .path = "includes/zstd/lib" });
    zstd.addIncludePath(.{ .path = "includes/zstd/lib/decompress" });
    zstd.addIncludePath(.{ .path = "includes/zstd/lib/dictBuilder" });
    zstd.addIncludePath(.{ .path = "includes/zstd/lib/deprecated" });
    zstd.addIncludePath(.{ .path = "includes/zstd/lib/common" });
    zstd.addIncludePath(.{ .path = "includes/zstd/lib/legacy" });
    zstd.addIncludePath(.{ .path = "includes/zstd/lib/compress" });

    const flags = [_][]const u8{};

    zstd.addCSourceFiles(&.{
        "includes/zstd/lib/decompress/zstd_decompress_block.c",
        "includes/zstd/lib/decompress/huf_decompress.c",
        "includes/zstd/lib/decompress/huf_decompress_amd64.S",
        "includes/zstd/lib/decompress/zstd_ddict.c",
        "includes/zstd/lib/decompress/zstd_decompress.c",
        "includes/zstd/lib/dictBuilder/divsufsort.c",
        "includes/zstd/lib/dictBuilder/zdict.c",
        "includes/zstd/lib/dictBuilder/cover.c",
        "includes/zstd/lib/dictBuilder/fastcover.c",
        "includes/zstd/lib/deprecated/zbuff_common.c",
        "includes/zstd/lib/deprecated/zbuff_compress.c",
        "includes/zstd/lib/deprecated/zbuff_decompress.c",
        "includes/zstd/lib/common/xxhash.c",
        "includes/zstd/lib/common/pool.c",
        "includes/zstd/lib/common/error_private.c",
        "includes/zstd/lib/common/debug.c",
        "includes/zstd/lib/common/fse_decompress.c",
        "includes/zstd/lib/common/zstd_common.c",
        "includes/zstd/lib/common/entropy_common.c",
        "includes/zstd/lib/common/threading.c",
        "includes/zstd/lib/legacy/zstd_v02.c",
        "includes/zstd/lib/legacy/zstd_v06.c",
        "includes/zstd/lib/legacy/zstd_v03.c",
        "includes/zstd/lib/legacy/zstd_v05.c",
        "includes/zstd/lib/legacy/zstd_v01.c",
        "includes/zstd/lib/legacy/zstd_v04.c",
        "includes/zstd/lib/legacy/zstd_v07.c",
        "includes/zstd/lib/compress/zstd_ldm.c",
        "includes/zstd/lib/compress/zstd_lazy.c",
        "includes/zstd/lib/compress/zstd_fast.c",
        "includes/zstd/lib/compress/zstd_compress.c",
        "includes/zstd/lib/compress/huf_compress.c",
        "includes/zstd/lib/compress/zstd_compress_sequences.c",
        "includes/zstd/lib/compress/fse_compress.c",
        "includes/zstd/lib/compress/hist.c",
        "includes/zstd/lib/compress/zstd_compress_literals.c",
        "includes/zstd/lib/compress/zstdmt_compress.c",
        "includes/zstd/lib/compress/zstd_double_fast.c",
        "includes/zstd/lib/compress/zstd_opt.c",
        "includes/zstd/lib/compress/zstd_compress_superblock.c",
    }, &flags);

    zstd.linkLibC();

    b.installArtifact(zstd);

    const exe = b.addExecutable(.{
        .name = "zig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(zstd);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
