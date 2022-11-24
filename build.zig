const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const LibExeObjStep = std.build.LibExeObjStep;

pub fn build(b: *std.build.Builder) !void {
    const src_path = "src/libsodium";
    const src_dir = try fs.Dir.openIterableDir(fs.cwd(), src_path, .{ .no_follow = true });

    var target = b.standardTargetOptions(.{});
    var mode = b.standardReleaseOptions();

    const static = b.addStaticLibrary("sodium", null);
    const shared = b.addSharedLibrary("sodium", null, .unversioned);
    shared.strip = true;
    static.strip = true;

    const libs = [_]*LibExeObjStep{ static, shared };

    const prebuilt_version_file_path = "builds/msvc/version.h";
    const version_file_path = "include/sodium/version.h";

    if (src_dir.dir.access(version_file_path, .{ .mode = .read_only })) {} else |_| {
        try fs.cwd().copyFile(prebuilt_version_file_path, src_dir.dir, version_file_path, .{});
    }

    for (libs) |lib| {
        lib.setTarget(target);
        lib.setBuildMode(mode);
        lib.install();
        if (mode != .Debug) {
            lib.strip = true;
        }
        lib.linkLibC();

        lib.addIncludePath("src/libsodium/include/sodium");
        lib.defineCMacro("CONFIGURED", "1");
        lib.defineCMacro("DEV_MODE", "1");
        lib.defineCMacro("_GNU_SOURCE", "1");
        lib.defineCMacro("HAVE_INLINE_ASM", "1");
        lib.defineCMacro("HAVE_TI_MODE", "1");
        lib.defineCMacro("HAVE_ATOMIC_OPS", "1");

        switch (target.getCpuArch()) {
            .x86_64 => {
                lib.defineCMacro("HAVE_AMD64_ASM", "1");
                lib.defineCMacro("HAVE_AVX_ASM", "1");
                lib.defineCMacro("HAVE_CPUID", "1");
                lib.defineCMacro("HAVE_MMINTRIN_H", "1");
                lib.defineCMacro("HAVE_EMMINTRIN_H", "1");
                lib.defineCMacro("HAVE_PMMINTRIN_H", "1");
            },
            .aarch64, .aarch64_be => {
                const cpu_features = target.getCpuFeatures();
                const has_neon = cpu_features.isEnabled(@enumToInt(std.Target.aarch64.Feature.neon));
                const has_crypto = cpu_features.isEnabled(@enumToInt(std.Target.aarch64.Feature.crypto));
                if (has_neon and has_crypto) {
                    lib.defineCMacro("HAVE_ARMCRYPTO", "1");
                }
            },
            .wasm32, .wasm64 => {
                lib.defineCMacro("__wasm__", "1");
            },
            else => {},
        }

        switch (target.getOsTag()) {
            .wasi => {
                lib.defineCMacro("__wasi__", "1");
            },
            else => {},
        }

        var allocator = heap.page_allocator;
        var walker = try src_dir.walk(allocator);
        while (try walker.next()) |entry| {
            const name = entry.basename;
            if (mem.endsWith(u8, name, ".c")) {
                const full_path = try fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.path });
                lib.addCSourceFiles(&.{full_path}, &.{
                    "-fvisibility=hidden",
                    "-fno-strict-aliasing",
                    "-fno-strict-overflow",
                    "-fwrapv",
                    "-flax-vector-conversions",
                });
            } else if (mem.endsWith(u8, name, ".S")) {
                const full_path = try fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.path });
                lib.addAssemblyFile(full_path);
            }
        }
    }

    const test_path = "test/default";
    const out_bin_path = "zig-out/bin";
    const test_dir = try fs.Dir.openIterableDir(fs.cwd(), test_path, .{ .no_follow = true });
    fs.Dir.makePath(fs.cwd(), out_bin_path) catch {};
    const out_bin_dir = try fs.Dir.openDir(fs.cwd(), out_bin_path, .{});
    try test_dir.dir.copyFile("run.sh", out_bin_dir, "run.sh", .{});
    var allocator = heap.page_allocator;
    var walker = try test_dir.walk(allocator);
    while (try walker.next()) |entry| {
        const name = entry.basename;
        if (mem.endsWith(u8, name, ".exp")) {
            try test_dir.dir.copyFile(name, out_bin_dir, name, .{});
            continue;
        }
        if (!mem.endsWith(u8, name, ".c")) {
            continue;
        }
        const exe_name = name[0 .. name.len - 2];
        var exe = b.addExecutable(exe_name, null);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.linkLibC();
        exe.linkLibrary(static);
        exe.addIncludePath("src/libsodium/include");
        exe.addIncludePath("test/quirks");
        const full_path = try fmt.allocPrint(allocator, "{s}/{s}", .{ test_path, entry.path });
        exe.addCSourceFiles(&.{full_path}, &.{});
        exe.strip = true;
        exe.install();
    }
}
