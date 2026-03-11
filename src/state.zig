const std = @import("std");

const zglfw = @import("zglfw");
const zm = @import("zmath");

const MeshType = @import("render.zig").MeshType;

pub const ObjectType = []const u8;

pub const ObjectState = struct {
    pos: zm.Vec,
    rot: f32,
    scale: f32,
    type: ObjectType,
    mesh_type: MeshType,
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

pub const ControllerType = enum { keyboard, gamepad };

pub const GameState = enum { starting, running, gameover };

pub const DebugState = struct {
    enabled: bool,
    current_update_perf_in_ns: u64,
    current_render_perf_in_ns: u64,
    avg_update_perf_in_ns: u64,
    avg_render_perf_in_ns: u64,
    update_tick_count: u64,
    registered_gamepad_guid: []u8,
    registered_gamepad_name: []u8,
};

pub const Config = struct {
    fps_target: i16,

    player_speed: f32,
    player_turn_speed: f32,

    shot_delay: f32,
    shot_speed: f32,

    asteroid_spawn_delay: f32,
    asteroid_speed: f32,
    asteroid_split_threshold: f32,
};

pub const State = struct {
    config: Config,
    game_state: GameState,
    debug_state: DebugState,

    player_name: []u8,
    controller_type: ControllerType,
    registered_joystick: ?zglfw.Joystick,
    joystick_deadzone: f32,

    objects: ObjectMap,
    queued_deletion_id_list: std.ArrayList(ObjectId),

    rng: std.Random.DefaultPrng,

    mesh_collision_data: std.ArrayList(f32),

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
            .fps_target = -1,

            .player_speed = 0.3,
            .player_turn_speed = 2.0,

            .shot_delay = 0.8,
            .shot_speed = 0.6,

            .asteroid_spawn_delay = 3.0,
            .asteroid_speed = 0.2,
            .asteroid_split_threshold = 0.07,
        };

        self.* = .{
            .config = config,
            .game_state = GameState.starting,
            .debug_state = .{
                .enabled = false,
                .current_render_perf_in_ns = 0,
                .current_update_perf_in_ns = 0,
                .avg_render_perf_in_ns = 0,
                .avg_update_perf_in_ns = 0,
                .update_tick_count = 0,
                .registered_gamepad_guid = "",
                .registered_gamepad_name = "",
            },

            .player_name = "",
            .controller_type = ControllerType.keyboard,
            .registered_joystick = null,
            .joystick_deadzone = 0.1,

            .objects = .init(allocator),
            .queued_deletion_id_list = .empty,

            .rng = prng,

            .mesh_collision_data = .empty,

            .frame_time_history = .{},
            .shot_timer = 0.0,
            .asteroid_spawn_timer = 0.0,
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.player_name);
        allocator.free(self.debug_state.registered_gamepad_guid);
        allocator.free(self.debug_state.registered_gamepad_name);

        while (self.frame_time_history.popFirst()) |node| {
            const data_point: *FrameStatsDataPoint = @fieldParentPtr("node", node);
            allocator.destroy(data_point);
        }
        self.mesh_collision_data.deinit(allocator);
        self.queued_deletion_id_list.deinit(allocator);
        self.objects.deinit();
    }

    pub fn startGame(self: *State) void {
        _ = self.createObject(
            ObjectState{
                .pos = zm.Vec{ 0.0, 0.0, 0.0, 0.0 },
                .rot = 0.0,
                .scale = 0.1,
                .type = "player",
                .mesh_type = MeshType.triangle,
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

    pub fn createObject(self: *State, object: ObjectState) error{OutOfMemory}!ObjectId {
        const id = next_free_object_id;
        // TODO: Find way to reuse IDs of deleted objects
        next_free_object_id += 1;
        try self.objects.put(id, object);

        return id;
    }

    pub fn getObjectPtr(self: *State, object_id: ObjectId) error{objectNotFound}!*ObjectState {
        return self.objects.getPtr(object_id) orelse error.objectNotFound;
    }

    pub fn getObject(self: *State, object_id: ObjectId) error{objectNotFound}!ObjectState {
        return self.objects.get(object_id) orelse error.objectNotFound;
    }

    pub fn getObjectType(self: *State, object_id: u32) error{objectNotFound}!ObjectType {
        const object = try self.getObjectPtr(object_id);
        return object.type;
    }

    pub fn removeObject(self: *State, object_id: ObjectId) void {
        _ = self.objects.remove(object_id);
    }

    pub fn removeObjectQueued(self: *State, allocator: std.mem.Allocator, object_id: ObjectId) error{OutOfMemory}!void {
        try self.queued_deletion_id_list.append(allocator, object_id);
    }

    pub fn removeQueuedObjects(self: *State) void {
        while (self.queued_deletion_id_list.items.len > 0) {
            const object_id = self.queued_deletion_id_list.pop().?;
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

    pub fn getObjectCollisionRadius(self: *State, object_id: ObjectId) error{objectNotFound}!f32 {
        const object = try self.getObjectPtr(object_id);
        return self.mesh_collision_data.items[@intFromEnum(object.mesh_type)] * object.scale;
    }
};

test "create object" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer std.testing.expect(gpa_state.deinit() == std.heap.Check.ok) catch unreachable;

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    const object = ObjectState{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.5,
        .scale = 0.1,
        .type = "test_type",
        .mesh_type = MeshType.triangle,
    };
    const o1_id = try state.createObject(object);

    std.debug.assert(state.objects.count() == 1);

    const state_object = state.getObjectPtr(o1_id) catch unreachable;
    const object_type = state.getObjectType(o1_id) catch unreachable;

    try std.testing.expect(zm.all(zm.isNearEqual(
        state_object.pos,
        object.pos,
        zm.f32x4s(std.math.floatEps(f32)),
    ), 4));
    try std.testing.expect(state_object.rot == object.rot);
    try std.testing.expect(state_object.scale == object.scale);
    try std.testing.expect(state_object.mesh_type == object.mesh_type);
    try std.testing.expect(std.mem.eql(u8, object_type, object.type));
}

test "remove object" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer std.testing.expect(gpa_state.deinit() == std.heap.Check.ok) catch unreachable;

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    const o1_id = try state.createObject(.{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.5,
        .scale = 0.1,
        .type = "test_type",
        .mesh_type = MeshType.triangle,
    });

    std.debug.assert(state.objects.count() == 1);

    state.removeObject(o1_id);

    try std.testing.expect(state.objects.count() == 0);
}

test "remove object queued" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer std.testing.expect(gpa_state.deinit() == std.heap.Check.ok) catch unreachable;

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    const o1_id = try state.createObject(.{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.5,
        .scale = 0.1,
        .type = "test_type",
        .mesh_type = MeshType.triangle,
    });

    std.debug.assert(state.objects.count() == 1);

    try state.removeObjectQueued(gpa, o1_id);

    try std.testing.expect(state.objects.count() == 1);
    try std.testing.expect(state.queued_deletion_id_list.items.len == 1);

    state.removeQueuedObjects();

    try std.testing.expect(state.objects.count() == 0);
    try std.testing.expect(state.queued_deletion_id_list.items.len == 0);
}

test "get all objects of type" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer std.testing.expect(gpa_state.deinit() == std.heap.Check.ok) catch unreachable;

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    const o1_id = try state.createObject(.{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.5,
        .scale = 0.1,
        .type = "test_type_1",
        .mesh_type = MeshType.triangle,
    });
    _ = try state.createObject(.{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.5,
        .scale = 0.1,
        .type = "test_type_2",
        .mesh_type = MeshType.triangle,
    });

    std.debug.assert(state.objects.count() == 2);

    var object_id_list: std.ArrayList(ObjectId) = .empty;
    defer object_id_list.deinit(gpa);
    try state.getAllObjectsOfType(gpa, "test_type_1", &object_id_list);

    try std.testing.expect(object_id_list.items.len == 1);
    try std.testing.expect(object_id_list.items[0] == o1_id);
}

test "get collision radius" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer std.testing.expect(gpa_state.deinit() == std.heap.Check.ok) catch unreachable;

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    const mesh_collision_radius = 0.5;

    try state.mesh_collision_data.append(gpa, mesh_collision_radius);

    const object = ObjectState{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.5,
        .scale = 0.1,
        .type = "test_type_1",
        .mesh_type = MeshType.triangle,
    };
    const o1_id = try state.createObject(object);

    try std.testing.expect(try state.getObjectCollisionRadius(o1_id) == mesh_collision_radius * object.scale);
}
