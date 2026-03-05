const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zm = @import("zmath");

const Render = @import("render.zig");

pub const ObjectType = []const u8;

pub const ObjectState = struct {
    pos: zm.Vec,
    rot: f32,
    scale: f32,
    type: ObjectType,
    mesh_type: Render.MeshType,
};

pub const FrameStatsData = std.DoublyLinkedList;

pub const FrameStatsDataPoint = struct {
    time: f64,
    fps: f64,
    avg_cpu_time: f64,
    avg_render_time: u64,
    node: FrameStatsData.Node,
};

pub const FrameStatsLine = struct {
    time_v: []const f64,
    fps_v: []const f64,
    avg_cpu_time_v: []const f64,
    avg_render_time_v: []const f64,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, frame_stats_data: FrameStatsData) !Self {
        const n = frame_stats_data.len();
        var time_v = try allocator.alloc(f64, n);
        var fps_v = try allocator.alloc(f64, n);
        var avg_cpu_time_v = try allocator.alloc(f64, n);
        var avg_render_time_v = try allocator.alloc(f64, n);
        var current = frame_stats_data.first;
        var i: usize = 0;
        while (current) |node| : ({
            current = node.next;
            i += 1;
        }) {
            const data_point: *FrameStatsDataPoint = @fieldParentPtr("node", node);
            time_v[i] = data_point.time;
            fps_v[i] = data_point.fps;
            avg_cpu_time_v[i] = data_point.avg_cpu_time;
            avg_render_time_v[i] = @as(f64, @floatFromInt(data_point.avg_render_time));
        }

        return .{
            .time_v = time_v,
            .fps_v = fps_v,
            .avg_cpu_time_v = avg_cpu_time_v,
            .avg_render_time_v = avg_render_time_v,
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.time_v);
        allocator.free(self.fps_v);
        allocator.free(self.avg_cpu_time_v);
        allocator.free(self.avg_render_time_v);
    }
};

pub const ObjectId = u32;
pub const ObjectMap = std.AutoHashMap(ObjectId, ObjectState);

var next_free_object_id: ObjectId = 0;

pub const GameState = enum { starting, running, gameover };

pub const DebugState = struct {
    enabled: bool,
    current_update_perf_in_ns: u64,
    current_render_perf_in_ns: u64,
    avg_update_perf_in_ns: u64,
    avg_render_perf_in_ns: u64,
    update_tick_count: u64,
};

pub const Config = struct {
    vsync: bool,
    fps_target: i16,

    player_speed: f32,

    shot_delay: f32,
    shot_speed: f32,

    asteroid_spawn_delay: f32,
    asteroid_speed: f32,
};

pub const State = struct {
    graphics: *Render.GraphicsState,
    config: Config,
    game_state: GameState,
    debug_state: DebugState,

    player_name: []u8,

    objects: ObjectMap,
    queued_deletion_id_list: std.ArrayList(ObjectId),

    rng: std.Random.DefaultPrng,

    frame_time_history: FrameStatsData,
    shot_timer: f32,
    asteroid_spawn_timer: f32,

    pub fn init(self: *State, allocator: std.mem.Allocator) !void {
        const prng: std.Random.DefaultPrng = .init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });

        const config = Config{
            .vsync = true,
            .fps_target = -1,

            .player_speed = 0.3,

            .shot_delay = 1.0,
            .shot_speed = 0.6,

            .asteroid_spawn_delay = 3.0,
            .asteroid_speed = 0.2,
        };

        self.* = .{
            .graphics = try Render.init(allocator),

            .frame_time_history = .{},

            .rng = prng,

            .game_state = GameState.starting,
            .config = config,

            .player_name = "",

            .objects = .init(allocator),
            .queued_deletion_id_list = .empty,

            .shot_timer = 0.0,
            .asteroid_spawn_timer = 0.0,

            .debug_state = .{
                .enabled = false,
                .current_render_perf_in_ns = 0,
                .current_update_perf_in_ns = 0,
                .avg_render_perf_in_ns = 0,
                .avg_update_perf_in_ns = 0,
                .update_tick_count = 0,
            },
        };

        self.setVSync(true);
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.player_name);

        while (self.frame_time_history.popFirst()) |node| {
            const data_point: *FrameStatsDataPoint = @fieldParentPtr("node", node);
            allocator.destroy(data_point);
        }
        self.queued_deletion_id_list.deinit(allocator);
        self.objects.deinit();

        Render.deinit(allocator, self.graphics);
        allocator.destroy(self.graphics);
    }

    pub fn startGame(self: *State) void {
        _ = self.createObject(
            ObjectState{
                .pos = zm.Vec{ 0.0, 0.0, 0.0, 0.0 },
                .rot = 0.0,
                .scale = 0.1,
                .type = "player",
                .mesh_type = Render.MeshType.triangle,
            },
        ) catch unreachable;

        self.game_state = GameState.running;
    }

    pub fn gameOver(self: *State) void {
        var objects_iterator = self.objects.iterator();
        while (objects_iterator.next()) |object| {
            self.removeObject(object.key_ptr.*);
        }
        self.game_state = GameState.gameover;
    }

    pub fn createObject(self: *State, object: ObjectState) !ObjectId {
        const id = next_free_object_id;
        // TODO: Find way to reuse IDs of deleted objects
        next_free_object_id += 1;
        try self.objects.put(id, object);

        return id;
    }

    pub fn getObjectPtr(self: *State, object_id: ObjectId) !*ObjectState {
        return self.objects.getPtr(object_id) orelse error.objectNotFound;
    }

    pub fn getObjectType(self: *State, object_id: u32) !ObjectType {
        const object = try self.getObjectPtr(object_id);
        return object.type;
    }

    pub fn removeObject(self: *State, object_id: ObjectId) void {
        _ = self.objects.remove(object_id);
    }

    pub fn removeObjectQueued(self: *State, allocator: std.mem.Allocator, object_id: ObjectId) !void {
        try self.queued_deletion_id_list.append(allocator, object_id);
    }

    pub fn removeQueuedObjects(self: *State) void {
        for (self.queued_deletion_id_list.items) |object_id| {
            self.removeObject(object_id);
        }
    }

    pub fn getAllObjectsOfType(self: *State, allocator: std.mem.Allocator, object_type: ObjectType, object_list: *std.ArrayList(ObjectId)) !void {
        var iterator = self.objects.iterator();
        // TODO: Cache results
        while (iterator.next()) |object| {
            if (std.mem.eql(u8, object.value_ptr.type, object_type)) {
                try object_list.append(allocator, object.key_ptr.*);
            }
        }
    }

    pub fn setVSync(self: *State, value: bool) void {
        const gctx = self.graphics.gctx;
        self.config.vsync = value;
        if (value) {
            if (self.debug_state.enabled) {
                std.debug.print("VSync on\n", .{});
            }
            gctx.swapchain_descriptor.present_mode = zgpu.wgpu.PresentMode.fifo;
            // zglfw.swapInterval(1);
        } else {
            if (self.debug_state.enabled) {
                std.debug.print("VSync off\n", .{});
            }
            gctx.swapchain_descriptor.present_mode = zgpu.wgpu.PresentMode.immediate;
            // zglfw.swapInterval(0);
        }

        gctx.swapchain.release();
        gctx.swapchain = gctx.device.createSwapChain(
            gctx.surface,
            gctx.swapchain_descriptor,
        );
    }
};
