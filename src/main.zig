const std = @import("std");
const Dmenu = @import("dmenu.zig").Dmenu;

const i3Error = error{
    MessageTooLong,
};

const StateError = error{
    IllegalStateError,
    CommandFailed,
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
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    // stdout comes with a newline, chop it off
    const fileName = try getSocketPath(gpa);
    defer gpa.free(fileName);

    const stream = try std.net.connectUnixSocket(fileName);
    try i3SendLen(stream, GET_TREE, 0);

    var messageBuf = try i3Recv(stream, gpa);
    defer gpa.free(messageBuf);

    var tokens = std.json.TokenStream.init(messageBuf);
    const options = .{ .ignore_unknown_fields = true, .allocator = gpa };
    const json = try std.json.parse(i3Container, &tokens, options);
    defer std.json.parseFree(i3Container, json, options);

    // Try to allocate enough so we don't need to resize anyway
    var windowNames = try std.ArrayList([]u8).initCapacity(gpa, 32);
    defer windowNames.deinit();
    var windowWorkspaces = try std.ArrayList(i8).initCapacity(gpa, 32);
    defer windowWorkspaces.deinit();
    var windowIds = try std.ArrayList(u64).initCapacity(gpa, 32);
    defer windowIds.deinit();

    for (json.nodes) |outputContainer| {
        for (outputContainer.nodes) |conContainer| {
            for (conContainer.nodes) |workspaceContainer| {
                if (workspaceContainer.num) |num| {
                    try fetchWorkspace(workspaceContainer, num, &windowNames, &windowWorkspaces, &windowIds);
                }
            }
        }
    }

    var windowNamesFormatted = try gpa.alloc([]u8, windowNames.items.len);
    var windowIndex: u32 = 0;
    defer {
        var freeIndex: u32 = 0;
        while (freeIndex < windowIndex) : (freeIndex += 1) {
            gpa.free(windowNamesFormatted[freeIndex]);
        }
        gpa.free(windowNamesFormatted);
    }
    while (windowIndex < windowNames.items.len) : (windowIndex += 1) {
        windowNamesFormatted[windowIndex] = try std.fmt.allocPrint(gpa, "{s} ({d})\n", .{ windowNames.items[windowIndex], windowWorkspaces.items[windowIndex] });
    }

    var selector = try Dmenu.init(gpa);
    defer selector.deinit();
    try selector.start();

    var index: u32 = 0;
    while (index < windowNamesFormatted.len) {
        try selector.writer().writeAll(windowNamesFormatted[index]);
        index += 1;
    }

    const stdout = (try selector.readAll(gpa, 1024)) orelse return;
    defer gpa.free(stdout);

    var findIndex: u32 = 0;
    while (findIndex < windowNamesFormatted.len) {
        if (stdout.len == windowNamesFormatted[findIndex].len and std.mem.eql(u8, stdout, windowNamesFormatted[findIndex])) {
            var intBuf: [16]u8 = undefined;

            if (false) {
                const intAsStr = try std.fmt.bufPrint(&intBuf, "{d}", .{windowWorkspaces.items[findIndex]});
                std.log.info("Switching to workspace number {d}", .{windowWorkspaces.items[findIndex]});
                const command = "workspace number ";
                try i3SendLen(stream, RUN_COMMAND, command.len + intAsStr.len);
                const writer = stream.writer();
                try writer.writeAll(command);
                try writer.writeAll(intAsStr);
            } else {
                const intAsStr = try std.fmt.bufPrint(&intBuf, "{d}", .{windowIds.items[findIndex]});
                std.log.info("Focusing window {s} in workspace {d}", .{ windowNames.items[findIndex], windowWorkspaces.items[findIndex] });
                const commandPrefix = "[id=";
                const commandSuffix = "] focus";
                const totalLen = commandPrefix.len + intAsStr.len + commandSuffix.len;
                try i3SendLen(stream, RUN_COMMAND, totalLen);
                const writer = stream.writer();
                try writer.writeAll(commandPrefix);
                try writer.writeAll(intAsStr);
                try writer.writeAll(commandSuffix);
            }
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
        return StateError.IllegalStateError;
    }

    const messageLength = try reader.readIntNative(u32);
    const messageType = try reader.readIntNative(u32);

    if (messageType != 0) {
        std.log.err("Expected message type {d} in reply, but received {d}. Terminating.", .{ GET_TREE, messageType });
        return StateError.IllegalStateError;
    }

    var messageBuf: []u8 = try gpa.alloc(u8, messageLength);
    defer gpa.free(messageBuf);

    const messageBufLen = try reader.read(messageBuf);
    if (messageBufLen != messageLength) {
        std.log.err("Expected {d} bytes, but received {d}. Terminating.", .{ messageLength, messageBufLen });
        return StateError.IllegalStateError;
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

fn i3Recv(stream: std.net.Stream, gpa: std.mem.Allocator) ![]u8 {
    const reader = stream.reader();

    var magicBuf: [MAGIC.len]u8 = undefined;
    const magicBufLen = try reader.read(magicBuf[0..]);
    if (magicBufLen != MAGIC.len or !std.mem.eql(u8, magicBuf[0..], MAGIC)) {
        const safeMagicBufLen = @minimum(magicBufLen, MAGIC.len);
        std.log.err("Expected magic value '{s}', but received '{s}'. Terminating.", .{ MAGIC, magicBuf[0..safeMagicBufLen] });
        return StateError.IllegalStateError;
    }

    const messageLength = try reader.readIntNative(u32);
    const messageType = try reader.readIntNative(u32);

    if (messageType != GET_TREE) {
        std.log.err("Expected message type {d} in reply, but received {d}. Terminating.", .{ GET_TREE, messageType });
        return StateError.IllegalStateError;
    }

    var messageBuf: []u8 = try gpa.alloc(u8, messageLength);
    errdefer gpa.free(messageBuf);

    const messageBufLen = try reader.read(messageBuf);
    if (messageBufLen != messageLength) {
        std.log.err("Expected {d} bytes, but received {d}. Terminating.", .{ messageLength, messageBufLen });
        return StateError.IllegalStateError;
    }

    return messageBuf;
}

fn fetchWorkspace(container: i3Container, workspace: i8, windowNames: *std.ArrayList([]u8), windowWorkspaces: *std.ArrayList(i8), windowIds: *std.ArrayList(u64)) std.mem.Allocator.Error!void {
    try windowNames.ensureUnusedCapacity(container.nodes.len);
    try windowWorkspaces.ensureUnusedCapacity(container.nodes.len);
    for (container.nodes) |windowConContainer| {
        if (windowConContainer.name) |name| {
            try windowNames.append(name);
            try windowWorkspaces.append(workspace);
            try windowIds.append(windowConContainer.window.?);
        }
        try fetchWorkspace(windowConContainer, workspace, windowNames, windowWorkspaces, windowIds);
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
                return StateError.CommandFailed;
            }
        },
        .Signal, .Stopped, .Unknown => {
            std.log.err("i3 exec was stopped. Terminating.", .{});
            return StateError.CommandFailed;
        },
    }

    return result.stdout[0 .. @maximum(1, result.stdout.len) - 1];
}
