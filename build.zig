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

    const xxhash = b.dependency("xxhash", .{
        .target = target,
        .optimize = optimize,
    });

    const zstd = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zwad",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();

    exe.addIncludePath(xxhash.path(""));
    exe.addCSourceFile(.{
        .file = xxhash.path("xxhash.c"),
        .flags = &.{},
    });

    exe.addIncludePath(zstd.path("lib"));
    exe.addIncludePath(zstd.path("lib/decompress"));
    exe.addIncludePath(zstd.path("lib/dictBuilder"));
    exe.addIncludePath(zstd.path("lib/deprecated"));
    exe.addIncludePath(zstd.path("lib/common"));
    //exe.addIncludePath(zstd.path("lib/legacy"));
    exe.addIncludePath(zstd.path("lib/compress"));

    exe.addCSourceFiles(.{
        .root = zstd.path("lib"),
        .files = &.{
            "decompress/zstd_decompress_block.c",
            "decompress/huf_decompress.c",
            "decompress/huf_decompress_amd64.S",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",
            "dictBuilder/divsufsort.c",
            "dictBuilder/zdict.c",
            "dictBuilder/cover.c",
            "dictBuilder/fastcover.c",
            "deprecated/zbuff_common.c",
            "deprecated/zbuff_compress.c",
            "deprecated/zbuff_decompress.c",
            "common/xxhash.c",
            "common/pool.c",
            "common/error_private.c",
            "common/debug.c",
            "common/fse_decompress.c",
            "common/zstd_common.c",
            "common/entropy_common.c",
            "common/threading.c",
            //"legacy/zstd_v01.c",
            //"legacy/zstd_v02.c",
            //"legacy/zstd_v06.c",
            //"legacy/zstd_v03.c",
            //"legacy/zstd_v05.c",
            //"legacy/zstd_v01.c",
            //"legacy/zstd_v04.c",
            //"legacy/zstd_v07.c",
            "compress/zstd_ldm.c",
            "compress/zstd_lazy.c",
            "compress/zstd_fast.c",
            "compress/zstd_compress.c",
            "compress/huf_compress.c",
            "compress/zstd_compress_sequences.c",
            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/zstd_compress_literals.c",
            "compress/zstdmt_compress.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_opt.c",
            "compress/zstd_compress_superblock.c",
        },
        .flags = &.{},
    });

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
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
