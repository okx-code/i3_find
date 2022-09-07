const std = @import("std");

const DmenuError = error{
    CommandFailed,
};

pub const Dmenu = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    process: *std.ChildProcess,

    pub fn init(allocator: std.mem.Allocator) !Dmenu {
        var process = try std.ChildProcess.init(&[_][]const u8{ "dmenu", "-i", "-l", "10" }, allocator);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        return Dmenu{ .allocator = allocator, .process = process };
    }

    pub fn deinit(self: *Dmenu) void {
        self.process.deinit();
    }

    pub fn start(self: *Dmenu) !void {
        try self.process.spawn();
    }

    pub fn writer(self: *Dmenu) std.io.Writer(std.fs.File, std.os.WriteError, std.fs.File.write) {
        return self.process.stdin.?.writer();
    }

    pub fn readAll(self: *Dmenu, allocator: std.mem.Allocator, max_size: usize) !?[]u8 {
        // close stdin
        self.process.stdin.?.close();
        self.process.stdin = null;

        const stdout = try self.process.stdout.?.reader().readAllAlloc(allocator, max_size);
        errdefer allocator.free(stdout);

        switch (try self.process.wait()) {
            .Exited => |status| {
                if (status == 1) {
                    // user decided not to choose any option
                    return null;
                } else if (status != 0) {
                    return DmenuError.CommandFailed;
                } else {
                    return stdout;
                }
            },
            .Signal, .Stopped, .Unknown => {
                return DmenuError.CommandFailed;
            },
        }
    }
};
