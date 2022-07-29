const std = @import("std");

const SocketPathError = error{
    CommandFailed,
};

const i3Error = error{
    MessageTooLong,
};

const i3Container = struct {
    type: []u8,
    name: ?[]u8 = null,
    num: ?i8 = null,
    window: ?u32 = null,
    nodes: []i3Container,
};

const MAGIC = "i3-ipc";
const RUN_COMMAND: u32 = 0;
const GET_TREE: u32 = 4;

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    // stdout comes with a newline, chop it off
    const fileName = try getSocketPath(gpa);
    defer gpa.free(fileName);

    const stream = try std.net.connectUnixSocket(fileName);
    try i3SendLen(stream, GET_TREE, 0);

    const reader = stream.reader();

    var magicBuf: [MAGIC.len]u8 = undefined;
    const magicBufLen = try reader.read(magicBuf[0..]);
    if (magicBufLen != MAGIC.len or !std.mem.eql(u8, magicBuf[0..], MAGIC)) {
        const safeMagicBufLen = @minimum(magicBufLen, MAGIC.len);
        std.log.err("Expected magic value '{s}', but received '{s}'. Terminating.", .{ MAGIC, magicBuf[0..safeMagicBufLen] });
        std.process.exit(1);
    }

    const messageLength = try reader.readIntNative(u32);
    const messageType = try reader.readIntNative(u32);

    if (messageType != GET_TREE) {
        std.log.err("Expected message type {d} in reply, but received {d}. Terminating.", .{ GET_TREE, messageType });
        std.process.exit(1);
    }

    var messageBuf: []u8 = try gpa.alloc(u8, messageLength);
    defer gpa.free(messageBuf);

    const messageBufLen = try reader.read(messageBuf);
    if (messageBufLen != messageLength) {
        std.log.err("Expected {d} bytes, but received {d}. Terminating.", .{ messageLength, messageBufLen });
        std.process.exit(1);
    }

    var tokens = std.json.TokenStream.init(messageBuf);
    const options = .{ .ignore_unknown_fields = true, .allocator = gpa };
    const json = try std.json.parse(i3Container, &tokens, options);
    defer std.json.parseFree(i3Container, json, options);

    // Try to allocate enough so we don't need to resize anyway
    var windowNames = try std.ArrayList([]u8).initCapacity(gpa, 32);
    defer windowNames.deinit();
    var windowWorkspaces = try std.ArrayList(i8).initCapacity(gpa, 32);
    defer windowWorkspaces.deinit();

    for (json.nodes) |outputContainer| {
        for (outputContainer.nodes) |conContainer| {
            for (conContainer.nodes) |workspaceContainer| {
                if (workspaceContainer.num) |num| {
                    try fetchAllWindowsRecursively(workspaceContainer, num, &windowNames, &windowWorkspaces);
                }
            }
        }
    }

    var maxLen: usize = 0;
    for (windowNames.items) |windowName| {
        maxLen = @maximum(maxLen, windowName.len);
    }

    var process = std.ChildProcess.init(&[_][]const u8{ "dmenu", "-i", "-l", "10" }, gpa);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;

    try process.spawn();

    var index: u32 = 0;
    while (index < windowNames.items.len) {
        try process.stdin.?.writer().print("{s} ({d})\n", .{ windowNames.items[index], windowWorkspaces.items[index] });
        index += 1;
    }

    process.stdin.?.close();
    process.stdin = null;

    const stdout = try process.stdout.?.reader().readAllAlloc(gpa, maxLen);
    defer gpa.free(stdout);

    switch (try process.wait()) {
        .Exited => |status| {
            if (status == 1) {
                // user decided not to choose any option
                std.process.exit(0);
            } else if (status != 0) {
                std.process.exit(1);
            }
        },
        .Signal, .Stopped, .Unknown => {
            std.process.exit(1);
        },
    }

    var findIndex: u32 = 0;
    var intBuf: [16]u8 = undefined;
    var prettyIntBuf: [22]u8 = undefined;
    while (findIndex < windowNames.items.len) {
        const windowName = windowNames.items[findIndex];
        const intAsStr = try std.fmt.bufPrint(intBuf[0..], "{d}", .{windowWorkspaces.items[findIndex]});
        const intBufSlice = try std.fmt.bufPrint(prettyIntBuf[0..], " ({s})\n", .{intAsStr});

        const middleLen = windowName.len;
        const endLen = middleLen + intBufSlice.len;

        if (stdout.len == endLen and std.mem.eql(u8, stdout[0..middleLen], windowName) and std.mem.eql(u8, stdout[middleLen..endLen], intBufSlice)) {
            std.debug.print("Switching to workspace number {d}\n", .{windowWorkspaces.items[findIndex]});
            const command = "workspace number ";
            try i3SendLen(stream, RUN_COMMAND, command.len + intAsStr.len);
            const writer = stream.writer();
            try writer.writeAll(command);
            try writer.writeAll(intAsStr);
            return;
        }
        findIndex += 1;
    }

    std.log.warn("No workspace found for window {s}", .{stdout});
}

fn readAll(stream: std.net.Stream, gpa: std.mem.Allocator) !void {
    const reader = stream.reader();
    var magicBuf: [MAGIC.len]u8 = undefined;
    const magicBufLen = try reader.read(magicBuf[0..]);
    if (magicBufLen != MAGIC.len or !std.mem.eql(u8, magicBuf[0..], MAGIC)) {
        const safeMagicBufLen = @minimum(magicBufLen, MAGIC.len);
        std.log.err("Expected magic value '{s}', but received '{s}'. Terminating.", .{ MAGIC, magicBuf[0..safeMagicBufLen] });
        std.process.exit(1);
    }

    const messageLength = try reader.readIntNative(u32);
    const messageType = try reader.readIntNative(u32);

    if (messageType != 0) {
        std.log.err("Expected message type {d} in reply, but received {d}. Terminating.", .{ GET_TREE, messageType });
        std.process.exit(1);
    }

    var messageBuf: []u8 = try gpa.alloc(u8, messageLength);
    defer gpa.free(messageBuf);

    const messageBufLen = try reader.read(messageBuf);
    if (messageBufLen != messageLength) {
        std.log.err("Expected {d} bytes, but received {d}. Terminating.", .{ messageLength, messageBufLen });
        std.process.exit(1);
    }

    std.debug.print("Buf {s}", .{messageBuf});
}

fn i3SendLen(stream: std.net.Stream, messageType: u32, messageLen: usize) !void {
    if (messageLen > std.math.maxInt(u32)) {
        return i3Error.MessageTooLong;
    }
    const writer = stream.writer();
    try writer.writeAll(MAGIC);
    try writer.writeIntNative(u32, @truncate(u32, messageLen));
    try writer.writeIntNative(u32, messageType);
}

fn fetchAllWindowsRecursively(container: i3Container, workspace: i8, windowNames: *std.ArrayList([]u8), windowWorkspaces: *std.ArrayList(i8)) std.mem.Allocator.Error!void {
    try windowNames.ensureUnusedCapacity(container.nodes.len);
    try windowWorkspaces.ensureUnusedCapacity(container.nodes.len);
    for (container.nodes) |windowConContainer| {
        if (windowConContainer.name) |name| {
            try windowNames.append(name);
            try windowWorkspaces.append(workspace);
        }
        try fetchAllWindowsRecursively(windowConContainer, workspace, windowNames, windowWorkspaces);
    }
}

fn getSocketPath(allocator: std.mem.Allocator) ![]u8 {
    var result = try std.ChildProcess.exec(.{ .allocator = allocator, .argv = &.{ "i3", "--get-socketpath" } });
    allocator.free(result.stderr); // don't care about stderr
    errdefer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |status| {
            if (status != 0) {
                std.log.err("i3 exec was terminated with non-successful code {d}. Terminating.", .{status});
                return SocketPathError.CommandFailed;
            }
        },
        .Signal, .Stopped, .Unknown => {
            std.log.err("i3 exec was stopped. Terminating.", .{});
            return SocketPathError.CommandFailed;
        },
    }

    return result.stdout[0..@maximum(0, result.stdout.len - 1)];
}
