const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const Target = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Compile = Build.Step.Compile;

const agility_version = "1.620.2";
const agility_version_major = "620";
const agility_dir = "AgilitySDK";

const agility_url = "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/" ++
    agility_version ++
    "/microsoft.direct3d.d3d12." ++
    agility_version ++
    ".nupkg";

pub const Backend = enum {
    auto,
    none,
    d3d11,
    d3d12,
    vk,
    wgpu,
    metal,
};

const Config = struct {
    backend: Backend,
    shared: bool,
    validation: bool,
    debug_names: bool,
    agility_sdk: bool,
    metal_shader_converter: bool,
    xlib: bool,
    wayland: bool,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const requested = b.option(Backend, "backend", "Graphics backend (default: platform)") orelse .auto;
    const backend = resolveBackend(requested, target.result.os.tag);
    const windows = target.result.os.tag == .windows;

    const config: Config = .{
        .backend = backend,
        .shared = b.option(bool, "shared", "Build NRI as a shared library") orelse false,
        .validation = b.option(bool, "validation", "Enable the validation backend") orelse true,
        .debug_names = b.option(bool, "debug_names", "Enable debug names and annotations") orelse true,
        .agility_sdk = b.option(bool, "agility_sdk", "Use the Agility SDK for D3D12") orelse (backend == .d3d12 and windows),
        .metal_shader_converter = b.option(bool, "metal_shader_converter", "Convert DXIL to Metal IR") orelse false,
        .xlib = b.option(bool, "xlib", "Enable the Xlib Vulkan surface") orelse true,
        .wayland = b.option(bool, "wayland", "Enable the Wayland Vulkan surface") orelse false,
    };

    if (config.agility_sdk and (backend != .d3d12 or !windows)) {
        @panic("the Agility SDK is only available for the D3D12 backend on Windows");
    }

    const agility: ?AgilitySdk = if (config.agility_sdk) addAgilitySdk(b, target) else null;
    const lib = try buildLibrary(b, target, optimize, config, agility);
    b.installArtifact(lib);
    inline for (.{ "NRI.h", "NRI.hlsl", "NRI.metal", "NRIDescs.h", "NRIMacro.h" }) |name| {
        b.installFile(b.fmt("Include/{s}", .{name}), b.fmt("include/{s}", .{name}));
    }
    b.installDirectory(.{
        .source_dir = b.path("Include/Extensions"),
        .install_dir = .header,
        .install_subdir = "Extensions",
    });

    if (agility) |sdk| installAgilitySdk(b, sdk, lib);
}

fn resolveBackend(requested: Backend, os: std.Target.Os.Tag) Backend {
    if (requested != .auto) return requested;
    return switch (os) {
        .windows => .d3d12,
        .macos => .metal,
        .linux => .vk,
        else => @panic("NRI has no default backend for this OS, pass -Dbackend"),
    };
}

fn buildLibrary(b: *Build, target: Target, optimize: OptimizeMode, config: Config, agility: ?AgilitySdk) !*Compile {
    const windows = target.result.os.tag == .windows;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(b.allocator);
    try files.appendSlice(b.allocator, &.{
        "Source/Creation/Creation.cpp",
        "Source/Shared/Shared.cpp",
    });

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{ "-std=c++17", "-fno-sanitize=enum" });

    if (windows) {
        mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
        mod.addCMacro("NOMINMAX", "1");
        mod.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
        mod.addCMacro("D3D12_ERROR_INVALID_REDIST", "-2005008381");
    }
    if (config.debug_names) mod.addCMacro("NRI_ENABLE_DEBUG_NAMES_AND_ANNOTATIONS", "1");
    if (config.validation) {
        mod.addCMacro("NRI_ENABLE_VALIDATION_SUPPORT", "1");
        try files.append(b.allocator, "Source/Validation/ImplVal.cpp");
    }
    if (config.shared) {
        mod.addCMacro("NRI_API", if (windows)
            "extern \"C\" __declspec(dllexport)"
        else
            "extern \"C\" __attribute__((visibility(\"default\")))");
    } else {
        mod.addCMacro("NRI_STATIC_LIBRARY", "1");
    }

    switch (config.backend) {
        .none => {
            mod.addCMacro("NRI_ENABLE_NONE_SUPPORT", "1");
            try files.append(b.allocator, "Source/NONE/ImplNONE.cpp");
        },
        .d3d11 => try addD3D11(b, mod, target, &files),
        .d3d12 => try addD3D12(b, mod, target, &files, &flags, config, agility),
        .vk => try addVulkan(b, mod, target, &files, config),
        .wgpu => try addWgpu(b, mod, target, &files),
        .metal => try addMetal(b, mod, target, &files, config),
        .auto => unreachable,
    }

    mod.addIncludePath(b.path("Include"));
    mod.addIncludePath(b.path("Source/Shared"));
    mod.addCSourceFiles(.{
        .files = files.items,
        .flags = flags.items,
        .language = .cpp,
    });

    return b.addLibrary(.{
        .name = "nri",
        .linkage = if (config.shared) .dynamic else .static,
        .root_module = mod,
    });
}

fn addD3D11(b: *Build, mod: *Module, target: Target, files: *std.ArrayList([]const u8)) !void {
    if (target.result.os.tag != .windows) @panic("the D3D11 backend targets Windows");

    const pix = try b.dependencyLazy("pix", .{});
    mod.addIncludePath(pix.path("include"));
    mod.addIncludePath(b.path("Scripts"));

    mod.addCMacro("NRI_ENABLE_D3D11_SUPPORT", "1");
    try files.append(b.allocator, "Source/D3D11/ImplD3D11.cpp");
    mod.linkSystemLibrary("d3d11", .{ .needed = true });
    mod.linkSystemLibrary("dxgi", .{ .needed = true });
    mod.linkSystemLibrary("dxguid", .{ .needed = true });
}

fn addD3D12(b: *Build, mod: *Module, target: Target, files: *std.ArrayList([]const u8), flags: *std.ArrayList([]const u8), config: Config, agility: ?AgilitySdk) !void {
    if (target.result.os.tag != .windows) @panic("the D3D12 backend targets Windows");

    const dx = try b.dependencyLazy("directx_headers", .{});
    const d3d12ma = try b.dependencyLazy("d3d12ma", .{});
    const pix = try b.dependencyLazy("pix", .{});

    mod.addIncludePath(dx.path("include"));
    mod.addIncludePath(dx.path("include/directx"));
    mod.addIncludePath(d3d12ma.path("include"));
    mod.addIncludePath(d3d12ma.path("src"));
    mod.addIncludePath(pix.path("include"));
    mod.addIncludePath(b.path("Scripts"));

    const guids = try b.root.joinString(b.allocator, "Scripts/d3d12_guids.h");
    try flags.appendSlice(b.allocator, &.{ "-include", guids });

    mod.addCMacro("NRI_ENABLE_D3D12_SUPPORT", "1");
    mod.addCMacro("NRI_AGILITY_SDK_VERSION_MAJOR", if (config.agility_sdk) agility_version_major else "D3D12_SDK_VERSION");
    if (agility) |sdk| {
        mod.addCMacro("NRI_ENABLE_AGILITY_SDK_SUPPORT", "1");
        mod.addIncludePath(sdk.include);
    }

    try files.append(b.allocator, "Source/D3D12/ImplD3D12.cpp");
    mod.linkSystemLibrary("d3d12", .{ .needed = true });
    mod.linkSystemLibrary("dxgi", .{ .needed = true });
    mod.linkSystemLibrary("dxguid", .{ .needed = true });
    mod.linkSystemLibrary("uuid", .{ .needed = true });
}

fn addVulkan(b: *Build, mod: *Module, target: Target, files: *std.ArrayList([]const u8), config: Config) !void {
    const headers = try b.dependencyLazy("vulkan_headers", .{});
    const vma = try b.dependencyLazy("vulkan_ma", .{});

    mod.addIncludePath(headers.path("include"));
    mod.addIncludePath(vma.path("include"));
    mod.addCMacro("NRI_ENABLE_VK_SUPPORT", "1");

    switch (target.result.os.tag) {
        .windows => {
            mod.addCMacro("VK_USE_PLATFORM_WIN32_KHR", "1");
            const sdk = b.graph.environ_map.get("VULKAN_SDK") orelse @panic("VULKAN_SDK is not set");
            const lib = try std.fs.path.join(b.allocator, &.{ sdk, "Lib", "vulkan-1.lib" });
            mod.addObjectFile(.{ .cwd_relative = lib });
        },
        .macos => {
            mod.addCMacro("VK_USE_PLATFORM_METAL_EXT", "1");
            mod.addCMacro("VK_ENABLE_BETA_EXTENSIONS", "1");
            mod.linkSystemLibrary("vulkan", .{ .needed = true });
        },
        .linux => {
            if (config.xlib) {
                mod.addCMacro("NRI_ENABLE_XLIB_SUPPORT", "1");
                mod.addCMacro("VK_USE_PLATFORM_XLIB_KHR", "1");
            }
            if (config.wayland) {
                mod.addCMacro("NRI_ENABLE_WAYLAND_SUPPORT", "1");
                mod.addCMacro("VK_USE_PLATFORM_WAYLAND_KHR", "1");
            }
            mod.linkSystemLibrary("vulkan", .{ .needed = true });
        },
        else => @panic("the Vulkan backend targets Windows, macOS, and Linux"),
    }

    try files.append(b.allocator, "Source/VK/ImplVK.cpp");
}

fn addWgpu(b: *Build, mod: *Module, target: Target, files: *std.ArrayList([]const u8)) !void {
    const os = switch (target.result.os.tag) {
        .windows => "windows",
        .macos => "macos",
        .linux => "linux",
        else => @panic("the WebGPU backend targets Windows, macOS, and Linux"),
    };
    const arch = if (target.result.cpu.arch.isAARCH64()) "arm" else "x86";
    if (target.result.cpu.arch.isAARCH64() and target.result.os.tag == .windows) {
        @panic("wgpu-native does not publish Windows ARM64 binaries");
    }

    const name = try std.fmt.allocPrint(b.allocator, "wgpu_{s}_{s}", .{ os, arch });
    const wgpu = try b.dependencyLazy(name, .{});

    const native = wgpu.path("lib/libwgpu_native.a");
    b.addNamedLazyPath("wgpu_native", native);

    mod.addIncludePath(wgpu.path("include"));
    mod.addObjectFile(native);
    mod.addCMacro("NRI_ENABLE_WGPU_SUPPORT", "1");
    try files.append(b.allocator, "Source/WGPU/ImplWGPU.cpp");

    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{ .needed = true });
        mod.linkSystemLibrary("userenv", .{ .needed = true });
    }
}

fn addMetal(b: *Build, mod: *Module, target: Target, files: *std.ArrayList([]const u8), config: Config) !void {
    if (target.result.os.tag != .macos) @panic("the Metal backend targets macOS");

    const metal = try b.dependencyLazy("metal_cpp", .{});
    mod.addIncludePath(metal.path(""));
    mod.addCMacro("NRI_ENABLE_METAL_SUPPORT", "1");
    mod.addCMacro("NRI_METAL_CPP_PRIVATE_IMPLEMENTATION", "1");

    mod.linkFramework("Metal", .{});
    mod.linkFramework("MetalFX", .{});
    mod.linkFramework("MetalKit", .{});
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("IOKit", .{});

    if (config.metal_shader_converter) {
        mod.addCMacro("NRI_ENABLE_METAL_SHADER_CONVERTER", "1");
        mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        mod.addRPathSpecial("/usr/local/lib");
        mod.linkSystemLibrary("metalirconverter", .{ .needed = true });
    }

    try files.append(b.allocator, "Source/Metal/ImplMetal.cpp");
    embedMetallib(b, mod);
}

fn embedMetallib(b: *Build, mod: *Module) void {
    const name = "InternalMetal";

    const compile = b.addSystemCommand(&.{
        "xcrun",         "-sdk",                      "macosx", "metal",
        "-std=metal4.0", "-mmacosx-version-min=26.0", "-c",
    });
    compile.addFileArg(b.path(b.fmt("Shaders/{s}.metal", .{name})));
    compile.addArg("-o");
    const air = compile.addOutputFileArg(b.fmt("{s}.air", .{name}));

    const link = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metallib" });
    link.addFileArg(air);
    link.addArg("-o");
    const metallib = link.addOutputFileArg(b.fmt("{s}.metallib", .{name}));

    const embed = b.addSystemCommand(&.{ "xxd", "-i", "-n" });
    embed.addArg(b.fmt("g_{s}_metallib", .{name}));
    embed.addFileArg(metallib);
    const header = embed.addOutputFileArg(b.fmt("{s}.metallib.h", .{name}));

    mod.addIncludePath(header.dirname());
}

const AgilitySdk = struct {
    step: *Build.Step,
    include: Build.LazyPath,
    bin: Build.LazyPath,
};

fn addAgilitySdk(b: *Build, target: Target) AgilitySdk {
    const fetch = b.addExecutable(.{
        .name = "agility_sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("Scripts/agility_sdk.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(fetch);
    run.addArg(agility_url);
    const sdk = run.addOutputDirectoryArg2("agility_sdk", .{ .make_absolute = true });
    const arch = if (target.result.cpu.arch.isAARCH64()) "arm64" else "x64";

    return .{
        .step = &run.step,
        .include = sdk.path(b, "build/native/include"),
        .bin = sdk.path(b, b.fmt("build/native/bin/{s}", .{arch})),
    };
}

fn installAgilitySdk(b: *Build, sdk: AgilitySdk, lib: *Compile) void {
    lib.step.dependOn(sdk.step);
    b.addNamedLazyPath("agility-sdk-bin", sdk.bin);

    const header = b.addNamedWriteFiles("agility-sdk-header").add("NRIAgilitySDK.h", b.fmt(
        \\#pragma once
        \\#include <stdint.h>
        \\#ifdef __cplusplus
        \\extern "C" {{
        \\#endif
        \\__declspec(dllexport) extern const uint32_t D3D12SDKVersion;
        \\const uint32_t D3D12SDKVersion = {s};
        \\__declspec(dllexport) extern const char* D3D12SDKPath;
        \\const char* D3D12SDKPath = "{s}/";
        \\#ifdef __cplusplus
        \\}}
        \\#endif
        \\
    , .{ agility_version_major, agility_dir }));

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = sdk.bin,
        .install_dir = .bin,
        .install_subdir = agility_dir,
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFile(header, "include/NRIAgilitySDK.h").step);
}
