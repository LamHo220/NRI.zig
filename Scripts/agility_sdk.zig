const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len == 3);

    const cwd = std.Io.Dir.cwd();
    const package_path = try std.fs.path.join(init.arena.allocator(), &.{ args[2], "agility-sdk.nupkg" });

    try download(init, args[1], package_path);
    try extract(init, package_path, args[2]);
    try cwd.deleteFile(init.io, package_path);
}

fn download(init: std.process.Init, url: []const u8, package_path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    const package = try std.Io.Dir.cwd().createFile(init.io, package_path, .{});
    errdefer package.close(init.io);

    var buffer: [64 * 1024]u8 = undefined;
    var writer = package.writer(init.io, &buffer);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });
    try writer.end();
    if (response.status != .ok) return error.DownloadFailed;
    package.close(init.io);
}

fn extract(init: std.process.Init, package_path: []const u8, output_dir: []const u8) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const package = try cwd.openFile(io, package_path, .{});
    defer package.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = package.reader(io, &buffer);

    const output = try cwd.openDir(io, output_dir, .{});
    defer output.close(io);

    var entries = try std.zip.Iterator.init(&reader);
    var entry_name: [std.fs.max_path_bytes]u8 = undefined;
    var extracted: usize = 0;
    while (try entries.next()) |entry| {
        const name = try entry.getFilename(&reader, &entry_name, .{});
        if (!neededByBuild(name)) continue;
        try entry.extract(&reader, .{}, &entry_name, output);
        if (!std.mem.endsWith(u8, name, "/")) extracted += 1;
    }
    if (extracted == 0) return error.NoSdkFiles;
}

fn neededByBuild(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".pdb")) return false;
    return std.mem.startsWith(u8, name, "build/native/include/") or
        std.mem.startsWith(u8, name, "build/native/bin/");
}
