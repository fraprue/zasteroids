const std = @import("std");
const Window = @import("zglfw").Window;
const zglfw = @import("zglfw");
const zm = @import("zmath");

const content_dir = @import("build_options").content_dir;

const Render = @import("render.zig");
const State = @import("state.zig");

const ScreenEdge = enum { north, east, south, west };

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        // std.debug.print("New path: {s}", .{path});
        try std.posix.chdir(path);
    }

    const state = try gpa.create(State.State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    const graphics = try gpa.create(Render.GraphicsState);
    defer gpa.destroy(graphics);

    try graphics.init(gpa);
    defer graphics.deinit(gpa);

    const window = graphics.window;

    for (graphics.meshes.items) |mesh| {
        try state.mesh_collision_data.append(gpa, mesh.collision_sphere_radius);
    }

    {
        var arena_allocator_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_allocator_state.deinit();
        const arena_allocator = arena_allocator_state.allocator();

        const full_gamepad_mapping_path = std.fs.path.joinZ(arena_allocator, &.{ std.fs.selfExeDirPathAlloc(arena_allocator) catch unreachable, content_dir, "gamecontrollerdb.txt" }) catch unreachable;
        const mapping_content = try std.fs.cwd().readFileAlloc(arena_allocator, full_gamepad_mapping_path, 1048576);
        const mapping_content_sentinel = std.fmt.allocPrintSentinel(arena_allocator, "{s}", .{
            mapping_content,
        }, 0) catch unreachable;

        const success = zglfw.Gamepad.updateMappings(mapping_content_sentinel);
        if (!success) {
            @panic("failed to update gamepad mappings");
        }
    }

    for (0..zglfw.Joystick.maximum_supported) |jid| {
        const joystick: zglfw.Joystick = @enumFromInt(jid);
        if (joystick.isPresent()) {
            state.registered_joystick = joystick;
            state.controller_type = State.ControllerType.gamepad;
            const joystick_guid = joystick.getGuid() catch "n/a";
            state.debug_state.registered_gamepad_guid = try gpa.alloc(u8, joystick_guid.len);
            @memcpy(state.debug_state.registered_gamepad_guid, joystick_guid[0..]);
            if (joystick.asGamepad()) |gamepad| {
                const gamepad_name = gamepad.getName();
                state.debug_state.registered_gamepad_name = try gpa.alloc(u8, gamepad_name.len);
                @memcpy(state.debug_state.registered_gamepad_name, gamepad_name[0..]);
            } else {
                @panic("Mapped gamepad: Missing mapping. Is GUID found in gamecontrollerdb.txt?");
            }
        }
    }

    var fps_timer = try std.time.Timer.start();

    var update_perf_timer = try std.time.Timer.start();
    var render_perf_timer = try std.time.Timer.start();
    var avg_perf_timer = try std.time.Timer.start();

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        fps_timer.reset();

        if (state.debug_state.enabled) {
            update_perf_timer.reset();
        }

        zglfw.pollEvents();

        update(gpa, state, window, graphics.gctx.stats.delta_time);

        if (state.debug_state.enabled) {
            state.debug_state.current_update_perf_in_ns += update_perf_timer.read();
            render_perf_timer.reset();
        }

        Render.render(gpa, state, graphics);

        if (state.debug_state.enabled) {
            state.debug_state.current_render_perf_in_ns += render_perf_timer.read();

            state.debug_state.update_tick_count += 1;
            if (avg_perf_timer.read() > 0.1 * std.time.ns_per_s) {
                state.debug_state.avg_update_perf_in_ns = state.debug_state.current_update_perf_in_ns / state.debug_state.update_tick_count;
                state.debug_state.avg_render_perf_in_ns = state.debug_state.current_render_perf_in_ns / state.debug_state.update_tick_count;

                state.debug_state.current_update_perf_in_ns = 0;
                state.debug_state.current_render_perf_in_ns = 0;
                state.debug_state.update_tick_count = 0;
                avg_perf_timer.reset();
            }
        }

        { // Frame Limiter
            if (state.config.fps_target <= 0) {
                continue;
            }
            const target_ns = @divTrunc(std.time.ns_per_s, @as(u64, @abs(state.config.fps_target)));

            while (fps_timer.read() < target_ns) {
                std.atomic.spinLoopHint();
            }
        }
    }
}

fn update(allocator: std.mem.Allocator, state: *State.State, window: *Window, delta_time: f32) void {
    if (state.game_state != State.GameState.running) {
        return;
    }

    state.shot_timer += delta_time;

    const delta_time_vec = zm.f32x4s(delta_time);
    const forward = [_]f32{ 0.0, 1.0 };

    var player_id_list: std.ArrayList(State.ObjectId) = .empty;
    defer player_id_list.deinit(allocator);
    state.getAllObjectsOfType(allocator, "player", &player_id_list) catch unreachable;
    const player_id = player_id_list.getLast();
    const player_ptr = state.getObjectPtr(player_id) catch unreachable;

    // Update Player
    {
        const move_speed = zm.f32x4s(state.config.player_speed);
        const turn_speed = state.config.player_turn_speed;
        const right = turn_speed * delta_time;

        const sincos = zm.sincos(player_ptr.rot);
        var rotated_forward = zm.Vec{ 0.0, 0.0, 0.0, 0.0 };
        rotated_forward[0] = forward[0] * sincos[1] - forward[1] * sincos[0];
        rotated_forward[1] = forward[0] * sincos[0] + forward[1] * sincos[1];

        // const forward_test = zm.Vec{ 0.0, 1.0, 0.0, 0.0 };
        // const rotated_forward_test = zm.mul(zm.rotationZ(player.rot), forward_test);
        // std.debug.print("Rotated Forward: x: {d}, y:{d}\n", .{ rotated_forward[0], rotated_forward[1] });
        // std.debug.print("Rotated Forward Test: x: {d}, y:{d}\n", .{ rotated_forward_test[0], rotated_forward_test[1] });

        rotated_forward = move_speed * delta_time_vec * rotated_forward;

        // Handle keyboard input
        {
            if (window.getKey(.w) == .press) {
                player_ptr.pos += rotated_forward;
                if (state.debug_state.enabled) {
                    std.debug.print("Forward: x: {d}, y:{d}\n", .{ player_ptr.pos[0], player_ptr.pos[1] });
                }
            } else if (window.getKey(.s) == .press) {
                player_ptr.pos -= rotated_forward;
                if (state.debug_state.enabled) {
                    std.debug.print("Backward: x: {d}, y:{d}\n", .{ player_ptr.pos[0], player_ptr.pos[1] });
                }
            }

            if (window.getKey(.d) == .press) {
                player_ptr.rot -= right;
                if (state.debug_state.enabled) {
                    std.debug.print("Right: rot: {d}\n", .{player_ptr.rot / std.math.pi});
                }
            } else if (window.getKey(.a) == .press) {
                player_ptr.rot += right;
                if (state.debug_state.enabled) {
                    std.debug.print("Left: rot: {d}\n", .{player_ptr.rot / std.math.pi});
                }
            }

            if (window.getKey(.space) == .press) {
                shoot(allocator, state, player_id) catch unreachable;
            }
        }

        // Handle gamepad input
        gamepad_input: {
            if (state.registered_joystick == null) {
                break :gamepad_input;
            }
            const joystick = state.registered_joystick.?;

            if (!joystick.isPresent()) {
                break :gamepad_input;
            }

            if (joystick.asGamepad()) |gamepad| {
                const gamepad_state: zglfw.Gamepad.State = gamepad.getState() catch .{};

                var direction = zm.f32x4s(0.0);
                var orientation = zm.f32x4s(0.0);
                for (std.enums.values(zglfw.Gamepad.Axis)) |axis| {
                    const axis_v = gamepad_state.axes[@intFromEnum(axis)];
                    if (axis == .left_x) {
                        direction[0] = axis_v;
                    }
                    if (axis == .left_y) {
                        direction[1] = -axis_v;
                    }
                    if (axis == .right_x) {
                        orientation[0] = axis_v;
                    }
                    if (axis == .right_y) {
                        orientation[1] = -axis_v;
                    }
                }

                if (zm.length2(direction)[0] >= state.joystick_deadzone) {
                    player_ptr.pos += move_speed * delta_time_vec * direction;
                }
                if (zm.length2(orientation)[0] >= state.joystick_deadzone) {
                    // Calculate 2D cross-product to determine direction of rotation
                    const target_orientation = rotated_forward[0] * orientation[1] - rotated_forward[1] * orientation[0];

                    const rotation_threshold = comptime 0.0001;
                    if (@abs(target_orientation) > rotation_threshold) {
                        player_ptr.rot += right * std.math.sign(target_orientation);
                    }
                }

                for (std.enums.values(zglfw.Gamepad.Button)) |button| {
                    const action = gamepad_state.buttons[@intFromEnum(button)];
                    if (action == .press and button == .dpad_up) {
                        player_ptr.pos += rotated_forward;
                        if (state.debug_state.enabled) {
                            std.debug.print("Forward: x: {d}, y:{d}\n", .{ player_ptr.pos[0], player_ptr.pos[1] });
                        }
                    } else if (action == .press and button == .dpad_down) {
                        player_ptr.pos -= rotated_forward;
                        if (state.debug_state.enabled) {
                            std.debug.print("Backward: x: {d}, y:{d}\n", .{ player_ptr.pos[0], player_ptr.pos[1] });
                        }
                    }

                    if (action == .press and button == .dpad_right) {
                        player_ptr.rot -= right;
                        if (state.debug_state.enabled) {
                            std.debug.print("Right: rot: {d}\n", .{player_ptr.rot / std.math.pi});
                        }
                    } else if (action == .press and button == .dpad_left) {
                        player_ptr.rot += right;
                        if (state.debug_state.enabled) {
                            std.debug.print("Left: rot: {d}\n", .{player_ptr.rot / std.math.pi});
                        }
                    }
                    if (action == .press and (button == .a or button == .right_bumper)) {
                        shoot(allocator, state, player_id) catch unreachable;
                    }
                }
            } else if (state.debug_state.enabled) {
                std.debug.print("Mapped gamepad: Missing mapping. Is GUID found in gamecontrollerdb.txt?\n", .{});
            }
        }
        wrapPosCoordinates(&player_ptr.pos);
    }

    // Update moving objects
    {
        // TODO: Parallelize this loop
        var objects_iterator = state.objects.iterator();
        while (objects_iterator.next()) |object_entry| {
            const object_id = object_entry.key_ptr.*;
            if (std.mem.eql(u8, state.getObjectType(object_id) catch unreachable, "player")) {
                continue;
            }
            const object = object_entry.value_ptr;

            const object_sincos = zm.sincos(object.rot);
            var object_rotated_forward = zm.Vec{ 0.0, 0.0, 0.0, 0.0 };
            object_rotated_forward[0] = forward[0] * object_sincos[1] - forward[1] * object_sincos[0];
            object_rotated_forward[1] = forward[0] * object_sincos[0] + forward[1] * object_sincos[1];

            var object_move_speed = zm.f32x4s(0.0);
            if (std.mem.eql(u8, state.getObjectType(object_id) catch unreachable, "asteroid")) {
                object_move_speed = zm.f32x4s(state.config.asteroid_speed);
            } else if (std.mem.eql(u8, state.getObjectType(object_id) catch unreachable, "projectile")) {
                object_move_speed = zm.f32x4s(state.config.shot_speed);
            }

            object_rotated_forward = object_move_speed * delta_time_vec * object_rotated_forward;

            object.pos += object_rotated_forward;

            if (std.mem.eql(u8, state.getObjectType(object_id) catch unreachable, "asteroid")) {
                wrapPosCoordinates(&object.pos);
            } else if (std.mem.eql(u8, state.getObjectType(object_id) catch unreachable, "projectile")) {
                // Remove out-of-bounds projectiles
                const margin = 0.2;
                if (@abs(object.pos[0]) > 1.0 + margin or @abs(object.pos[1]) > 1.0 + margin) {
                    state.removeObjectQueued(allocator, object_id) catch unreachable;
                }
            }
        }
    }

    // Check object collisions
    {
        var projectile_id_list: std.ArrayList(State.ObjectId) = .empty;
        defer projectile_id_list.deinit(allocator);
        state.getAllObjectsOfType(allocator, "projectile", &projectile_id_list) catch unreachable;

        var asteroid_id_list: std.ArrayList(State.ObjectId) = .empty;
        defer asteroid_id_list.deinit(allocator);
        state.getAllObjectsOfType(allocator, "asteroid", &asteroid_id_list) catch unreachable;

        for (asteroid_id_list.items) |asteroid_id| {
            if (collides(state, player_id, asteroid_id) catch unreachable) {
                state.gameOver();
                return;
            }
            for (projectile_id_list.items) |projectile_id| {
                if (collides(state, projectile_id, asteroid_id) catch unreachable) {
                    if (state.debug_state.enabled) {
                        std.debug.print("Detected collision between projectile {d} and asteroid {d}\n", .{ projectile_id, asteroid_id });
                    }
                    splitAsteroid(allocator, state, asteroid_id) catch unreachable;
                    state.removeObjectQueued(allocator, projectile_id) catch unreachable;
                }
            }
        }
    }

    // Spawn asteroids in fixed time intervals
    {
        state.asteroid_spawn_timer += delta_time;
        if (state.asteroid_spawn_timer > state.config.asteroid_spawn_delay) {
            state.asteroid_spawn_timer = 0.0;
            spawnAsteroid(allocator, state) catch unreachable;
        }
    }
    state.removeQueuedObjects();
    state.createQueuedObjects() catch unreachable;
}

fn normToVertexSpace(v: f32) f32 {
    return v * 2.0 - 1.0;
}

test "norm to vertex space conversion" {
    try std.testing.expect(normToVertexSpace(0.0) == -1.0);
    try std.testing.expect(normToVertexSpace(1.0) == 1.0);
    try std.testing.expect(normToVertexSpace(0.5) == 0.0);
}

fn shoot(allocator: std.mem.Allocator, state: *State.State, player_id: State.ObjectId) error{ objectNotFound, OutOfMemory }!void {
    const player_ptr = try state.getObjectPtr(player_id);

    if (state.shot_timer > state.config.shot_delay) {
        state.shot_timer = 0.0;
        try state.createObjectQueued(
            allocator,
            .{
                .pos = player_ptr.pos,
                .rot = player_ptr.rot,
                .scale = 0.02,
                .type = "projectile",
                .mesh_type = Render.MeshType.triangle,
            },
        );

        if (state.debug_state.enabled) {
            std.debug.print("Created Projectile at pos: {d}, {d}, rot: {d}\n", .{ player_ptr.pos[0], player_ptr.pos[1], player_ptr.rot });
        }
    }
}

fn wrapPosCoordinates(pos: *zm.Vec) void {
    if (pos[0] > 1.0) {
        pos[0] = -1.0;
    } else if (pos[0] < -1.0) {
        pos[0] = 1.0;
    }
    if (pos[1] > 1.0) {
        pos[1] = -1.0;
    } else if (pos[1] < -1.0) {
        pos[1] = 1.0;
    }
}

test "object position wrapping" {
    var unchanged_pos = zm.Vec{ 0.5, 0.5, 0.0, 0.0 };
    wrapPosCoordinates(&unchanged_pos);
    try std.testing.expect(zm.all(zm.isNearEqual(unchanged_pos, zm.Vec{ 0.5, 0.5, 0.0, 0.0 }, zm.f32x4s(0.0)), 2));

    var edge_pos = zm.Vec{ 1.0, -1.0, 0.0, 0.0 };
    wrapPosCoordinates(&edge_pos);
    try std.testing.expect(zm.all(zm.isNearEqual(edge_pos, zm.Vec{ 1.0, -1.0, 0.0, 0.0 }, zm.f32x4s(0.0)), 2));

    var outside_pos = zm.Vec{ 1.1, -1.1, 0.0, 0.0 };
    wrapPosCoordinates(&outside_pos);
    try std.testing.expect(zm.all(zm.isNearEqual(outside_pos, zm.Vec{ -1.0, 1.0, 0.0, 0.0 }, zm.f32x4s(0.0)), 2));

    var ignore_coordinates_pos = zm.Vec{ 0.0, 0.0, 1.1, -1.1 };
    wrapPosCoordinates(&ignore_coordinates_pos);
    try std.testing.expect(zm.all(zm.isNearEqual(ignore_coordinates_pos, zm.Vec{ 0.0, 0.0, 0.0, 0.0 }, zm.f32x4s(0.0)), 2));
}

fn spawnAsteroid(allocator: std.mem.Allocator, state: *State.State) error{OutOfMemory}!void {
    const screen_edge = @as(ScreenEdge, @enumFromInt(state.rng.random().intRangeAtMost(u2, 0, 3)));

    var pos = zm.Vec{ 0.0, 0.0, 0.0, 0.0 };
    const spread_angle = std.math.pi / 2.0;
    var rot = state.rng.random().float(f32) * spread_angle;
    switch (screen_edge) {
        ScreenEdge.north => {
            pos[0] = normToVertexSpace(state.rng.random().float(f32));
            pos[1] = 1.0;
            rot = rot + std.math.pi * 0.75;
        },
        ScreenEdge.east => {
            pos[0] = 1.0;
            pos[1] = normToVertexSpace(state.rng.random().float(f32));
            rot = rot + std.math.pi / 4.0;
        },
        ScreenEdge.south => {
            pos[0] = normToVertexSpace(state.rng.random().float(f32));
            pos[1] = -1.0;
            rot = rot - std.math.pi / 4.0;
        },
        ScreenEdge.west => {
            pos[0] = -1.0;
            pos[1] = normToVertexSpace(state.rng.random().float(f32));
            rot = rot - std.math.pi * 0.75;
        },
    }

    const rand_scale = @as(f32, @floatFromInt(state.rng.random().intRangeAtMost(i16, 50, 200))) / 1000.0;

    try state.createObjectQueued(
        allocator,
        .{
            .pos = pos,
            .rot = rot,
            .scale = rand_scale,
            .type = "asteroid",
            .mesh_type = Render.MeshType.asteroid,
        },
    );
    if (state.debug_state.enabled) {
        std.debug.print("Created Asteroid at edge: {}, pos: {d}, {d}, rot: {d}\n", .{ screen_edge, pos[0], pos[1], rot });
    }
}

fn splitAsteroid(allocator: std.mem.Allocator, state: *State.State, asteroid_id: State.ObjectId) error{OutOfMemory}!void {
    const asteroid = state.getObject(asteroid_id) catch unreachable;

    if (asteroid.scale >= state.config.asteroid_split_threshold) {
        const spread_angle = comptime std.math.degreesToRadians(20);
        const splitted_asteroid_1 = State.ObjectState{
            .pos = asteroid.pos,
            .rot = asteroid.rot - spread_angle,
            .scale = asteroid.scale * 0.5,
            .type = "asteroid",
            .mesh_type = Render.MeshType.asteroid,
        };
        try state.createObjectQueued(allocator, splitted_asteroid_1);
        if (state.debug_state.enabled) {
            std.debug.print("Created Asteroid by splitting asteroid {}, pos: {d}, {d}, rot: {d}\n", .{
                asteroid_id,
                splitted_asteroid_1.pos[0],
                splitted_asteroid_1.pos[1],
                splitted_asteroid_1.rot,
            });
        }

        var splitted_asteroid_2 = splitted_asteroid_1;
        splitted_asteroid_2.rot = asteroid.rot + spread_angle;

        try state.createObjectQueued(allocator, splitted_asteroid_2);
        if (state.debug_state.enabled) {
            std.debug.print("Created Asteroid by splitting asteroid {}, pos: {d}, {d}, rot: {d}\n", .{
                asteroid_id,
                splitted_asteroid_2.pos[0],
                splitted_asteroid_2.pos[1],
                splitted_asteroid_2.rot,
            });
        }
    }
    try state.removeObjectQueued(allocator, asteroid_id);
}

fn collides(state: *State.State, o1_id: State.ObjectId, o2_id: State.ObjectId) error{objectNotFound}!bool {
    const o1 = try state.getObjectPtr(o1_id);
    const o2 = try state.getObjectPtr(o2_id);

    const x_dist = o2.pos[0] - o1.pos[0];
    const y_dist = o2.pos[1] - o1.pos[1];
    const distance = std.math.sqrt(x_dist * x_dist + y_dist * y_dist);

    const o1_collision_radius = try state.getObjectCollisionRadius(o1_id);
    const o2_collision_radius = try state.getObjectCollisionRadius(o2_id);

    return distance <= (o1_collision_radius + o2_collision_radius);
}

test "object collision" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer std.testing.expect(gpa_state.deinit() == std.heap.Check.ok) catch unreachable;

    const state = try gpa.create(State.State);
    defer gpa.destroy(state);

    try state.init(gpa);
    defer state.deinit(gpa);

    try state.mesh_collision_data.append(gpa, 0.1);

    const o1_id = try state.createObject(.{
        .pos = zm.Vec{ 0.0, 0.0, 0.0, 0.0 },
        .rot = 0.0,
        .scale = 0.1,
        .type = "",
        .mesh_type = Render.MeshType.triangle,
    });
    const o2_id = try state.createObject(.{
        .pos = zm.Vec{ 0.0, 0.0, 0.0, 0.0 },
        .rot = 0.0,
        .scale = 0.1,
        .type = "",
        .mesh_type = Render.MeshType.triangle,
    });
    const o3_id = try state.createObject(.{
        .pos = zm.Vec{ 1.0, 0.0, 0.0, 0.0 },
        .rot = 0.0,
        .scale = 0.1,
        .type = "",
        .mesh_type = Render.MeshType.triangle,
    });

    try std.testing.expect(try collides(state, o1_id, o2_id));
    try std.testing.expect(!try collides(state, o1_id, o3_id));
}
