const std = @import("std");
const zm = @import("zmath");

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

    var fps_timer = try std.time.Timer.start();

    var update_perf_timer = try std.time.Timer.start();
    var render_perf_timer = try std.time.Timer.start();
    var avg_perf_timer = try std.time.Timer.start();

    while (!state.graphics.window.shouldClose() and state.graphics.window.getKey(.escape) != .press) {
        fps_timer.reset();

        if (state.debug_state.enabled) {
            update_perf_timer.reset();
        }

        update(state, gpa);

        if (state.debug_state.enabled) {
            state.debug_state.current_update_perf_in_ns += update_perf_timer.read();
            render_perf_timer.reset();
        }

        Render.render(state, gpa);

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

fn update(state: *State.State, allocator: std.mem.Allocator) void {
    if (state.game_state != State.GameState.running) {
        return;
    }
    const delta_time = zm.f32x4s(state.graphics.gctx.stats.delta_time);
    const forward = [_]f32{ 0.0, 1.0 };

    var player_id_list: std.ArrayList(State.ObjectId) = .empty;
    defer player_id_list.deinit(allocator);
    state.getAllObjectsOfType(allocator, "player", &player_id_list) catch unreachable;
    const player = state.getObjectPtr(player_id_list.getLast()) catch unreachable;

    // Update Player
    {
        const move_speed = zm.f32x4s(state.config.player_speed);
        const turn_speed = 2.0;

        const sincos = zm.sincos(player.rot);
        var rotated_forward = zm.Vec{ 0.0, 0.0, 0.0, 0.0 };
        rotated_forward[0] = forward[0] * sincos[1] - forward[1] * sincos[0];
        rotated_forward[1] = forward[0] * sincos[0] + forward[1] * sincos[1];

        // const forward_test = zm.Vec{ 0.0, 1.0, 0.0, 0.0 };
        // const rotated_forward_test = zm.mul(zm.rotationZ(player.rot), forward_test);
        // std.debug.print("Rotated Forward: x: {d}, y:{d}\n", .{ rotated_forward[0], rotated_forward[1] });
        // std.debug.print("Rotated Forward Test: x: {d}, y:{d}\n", .{ rotated_forward_test[0], rotated_forward_test[1] });

        rotated_forward = move_speed * delta_time * rotated_forward;

        if (state.graphics.window.getKey(.w) == .press) {
            player.pos += rotated_forward;
            if (state.debug_state.enabled) {
                std.debug.print("Forward: x: {d}, y:{d}\n", .{ player.pos[0], player.pos[1] });
            }
        } else if (state.graphics.window.getKey(.s) == .press) {
            player.pos -= rotated_forward;
            if (state.debug_state.enabled) {
                std.debug.print("Backward: x: {d}, y:{d}\n", .{ player.pos[0], player.pos[1] });
            }
        }

        const right = turn_speed * delta_time[0];
        if (state.graphics.window.getKey(.d) == .press) {
            player.rot -= right;
            if (state.debug_state.enabled) {
                std.debug.print("Right: rot: {d}\n", .{player.rot / std.math.pi});
            }
        } else if (state.graphics.window.getKey(.a) == .press) {
            player.rot += right;
            if (state.debug_state.enabled) {
                std.debug.print("Left: rot: {d}\n", .{player.rot / std.math.pi});
            }
        }

        wrapPosCoordinates(&player.pos);

        state.shot_timer += delta_time[0];
        if (state.graphics.window.getKey(.space) == .press) {
            if (state.shot_timer > state.config.shot_delay) {
                state.shot_timer = 0.0;
                _ = state.createObject(
                    State.ObjectState{
                        .pos = player.pos,
                        .rot = player.rot,
                        .scale = 0.02,
                        .type = "projectile",
                        .mesh_type = Render.MeshType.triangle,
                    },
                ) catch unreachable;

                if (state.debug_state.enabled) {
                    std.debug.print("Created Projectile at pos: {d}, {d}, rot: {d}\n", .{ player.pos[0], player.pos[1], player.rot });
                }
            }
        }
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

            object_rotated_forward = object_move_speed * delta_time * object_rotated_forward;

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
            const asteroid = state.getObjectPtr(asteroid_id) catch unreachable;
            if (collides(state, player, asteroid)) {
                state.gameOver();
                return;
            }
            for (projectile_id_list.items) |projectile_id| {
                const projectile = state.getObjectPtr(projectile_id) catch unreachable;
                if (collides(state, projectile, asteroid)) {
                    state.removeObjectQueued(allocator, asteroid_id) catch unreachable;
                    state.removeObjectQueued(allocator, projectile_id) catch unreachable;
                    if (state.debug_state.enabled) {
                        std.debug.print("Detected collision between projectile {d} and asteroid {d}\n", .{ projectile_id, asteroid_id });
                    }
                }
            }
        }
    }

    // Spawn asteroids in fixed time intervals
    {
        state.asteroid_spawn_timer += delta_time[0];
        if (state.asteroid_spawn_timer > state.config.asteroid_spawn_delay) {
            state.asteroid_spawn_timer = 0.0;
            spawnAsteroid(state);
        }
    }
    state.removeQueuedObjects();
}

fn normToVertexSpace(v: f32) f32 {
    return v * 2.0 - 1.0;
}

test "norm to vertex space conversion" {
    try std.testing.expect(normToVertexSpace(0.0) == -1.0);
    try std.testing.expect(normToVertexSpace(1.0) == 1.0);
    try std.testing.expect(normToVertexSpace(0.5) == 0.0);
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

fn spawnAsteroid(state: *State.State) void {
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

    _ = state.createObject(
        .{
            .pos = pos,
            .rot = rot,
            .scale = 0.1,
            .type = "asteroid",
            .mesh_type = Render.MeshType.asteroid,
        },
    ) catch unreachable;
    if (state.debug_state.enabled) {
        std.debug.print("Created Asteroid at edge: {}, pos: {d}, {d}, rot: {d}\n", .{ screen_edge, pos[0], pos[1], rot });
    }
}

fn collides(state: *State.State, o1: *State.ObjectState, o2: *State.ObjectState) bool {
    const x_dist = o2.pos[0] - o1.pos[0];
    const y_dist = o2.pos[1] - o1.pos[1];
    const distance = std.math.sqrt(x_dist * x_dist + y_dist * y_dist);

    const o1_collision_radius = state.graphics.meshes.items[@intFromEnum(o1.mesh_type)].collision_sphere_radius * o1.scale;
    const o2_collision_radius = state.graphics.meshes.items[@intFromEnum(o2.mesh_type)].collision_sphere_radius * o2.scale;

    return distance <= (o1_collision_radius + o2_collision_radius);
}

// TODO: Add collision test
