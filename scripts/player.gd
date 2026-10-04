extends CharacterBody3D

## Surface-walking first-person controller.
##
## The key trick is that "up" is dynamic. A detected surface normal becomes
## the new up_direction, so Godot's CharacterBody3D slide/floor logic can
## operate on walls and ceilings as if they were normal ground.

@export_category("Movement")
@export var move_speed: float = 5.5
@export var sprint_multiplier: float = 1.65
@export var acceleration: float = 24.0
@export var braking: float = 30.0
@export var gravity: float = 18.0

@export_category("Surface walking")
@export var surface_probe_distance: float = 1.35
@export var support_probe_distance: float = 0.85
@export var reorientation_speed: float = 7.0
@export var normal_change_threshold: float = 0.82

@export_category("Look")
@export var mouse_sensitivity: float = 0.0023
@export var max_pitch: float = 1.45

@onready var view_pivot: Node3D = $ViewPivot

var surface_up: Vector3 = Vector3.UP
var target_surface_up: Vector3 = Vector3.UP
var pitch: float = 0.0
var _mouse_captured := true
var _last_surface_name := "FLOOR"


func _ready() -> void:
    up_direction = surface_up
    floor_max_angle = 1.82
    floor_snap_length = 0.28
    safe_margin = 0.03
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    view_pivot.rotation.x = pitch


func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and _mouse_captured:
        rotate_object_local(Vector3.UP, -event.screen_relative.x * mouse_sensitivity)

        pitch = clamp(
            pitch - event.screen_relative.y * mouse_sensitivity,
            -max_pitch,
            max_pitch
        )
        view_pivot.rotation.x = pitch

    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == KEY_ESCAPE:
            _mouse_captured = false
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    if event is InputEventMouseButton and event.pressed:
        _mouse_captured = true
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
    var detected_normal := _find_surface_normal()

    if detected_normal.length_squared() > 0.0:
        if detected_normal.dot(surface_up) < normal_change_threshold:
            target_surface_up = detected_normal.normalized()

    var blend := 1.0 - exp(-reorientation_speed * delta)
    var old_up := surface_up
    surface_up = surface_up.slerp(target_surface_up, blend).normalized()
    up_direction = surface_up

    if old_up.dot(surface_up) < 0.999:
        _align_body_to_surface(surface_up, _best_tangent_direction())

    var input_2d := Vector2(
        float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
        float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
    )
    if input_2d.length_squared() > 1.0:
        input_2d = input_2d.normalized()

    var forward := -global_transform.basis.z
    var right := global_transform.basis.x
    var desired_direction := right * input_2d.x + forward * input_2d.y
    desired_direction = desired_direction - surface_up * desired_direction.dot(surface_up)

    if desired_direction.length_squared() > 0.0001:
        desired_direction = desired_direction.normalized()
        var speed := move_speed
        if Input.is_key_pressed(KEY_SHIFT):
            speed *= sprint_multiplier

        var planar_velocity := velocity - surface_up * velocity.dot(surface_up)
        planar_velocity = planar_velocity.move_toward(
            desired_direction * speed,
            acceleration * delta
        )
        var normal_velocity := velocity.dot(surface_up)

        if _has_support():
            normal_velocity = minf(normal_velocity, 0.0)
        else:
            normal_velocity -= gravity * delta

        velocity = planar_velocity + surface_up * normal_velocity
    else:
        var planar_velocity := velocity - surface_up * velocity.dot(surface_up)
        planar_velocity = planar_velocity.move_toward(Vector3.ZERO, braking * delta)

        var normal_velocity := velocity.dot(surface_up)
        if _has_support():
            normal_velocity = 0.0
        else:
            normal_velocity -= gravity * delta

        velocity = planar_velocity + surface_up * normal_velocity

    move_and_slide()

    if _has_support():
        apply_floor_snap()

    _update_surface_name()


func _find_surface_normal() -> Vector3:
    var forward := -global_transform.basis.z

    var ahead := _raycast(global_position, forward, surface_probe_distance)
    if not ahead.is_empty():
        var ahead_normal: Vector3 = ahead.normal.normalized()
        if ahead_normal.dot(surface_up) < 0.72:
            return ahead_normal

    var support := _raycast(
        global_position + surface_up * 0.12,
        -surface_up,
        support_probe_distance
    )
    if not support.is_empty():
        var support_normal: Vector3 = support.normal.normalized()
        if support_normal.dot(surface_up) > 0.35:
            return support_normal

    var right := global_transform.basis.x
    var left_hit := _raycast(global_position, -right, surface_probe_distance)
    if not left_hit.is_empty():
        var left_normal: Vector3 = left_hit.normal.normalized()
        if left_normal.dot(surface_up) < 0.55:
            return left_normal

    var right_hit := _raycast(global_position, right, surface_probe_distance)
    if not right_hit.is_empty():
        var right_normal: Vector3 = right_hit.normal.normalized()
        if right_normal.dot(surface_up) < 0.55:
            return right_normal

    return Vector3.ZERO


func _raycast(from: Vector3, direction: Vector3, distance: float) -> Dictionary:
    if direction.length_squared() < 0.0001:
        return {}

    var query := PhysicsRayQueryParameters3D.create(
        from,
        from + direction.normalized() * distance
    )
    query.collision_mask = 1
    query.collide_with_bodies = true
    query.collide_with_areas = false
    query.exclude = [self]

    return get_world_3d().direct_space_state.intersect_ray(query)


func _has_support() -> bool:
    var hit := _raycast(
        global_position + surface_up * 0.12,
        -surface_up,
        support_probe_distance
    )
    if hit.is_empty():
        return false

    return hit.normal.normalized().dot(surface_up) > 0.35


func _best_tangent_direction() -> Vector3:
    var current_forward := -global_transform.basis.z
    var tangent := current_forward - surface_up * current_forward.dot(surface_up)

    if tangent.length_squared() > 0.01:
        return tangent.normalized()

    var fallback := Vector3.UP - surface_up * Vector3.UP.dot(surface_up)
    if fallback.length_squared() > 0.01:
        return fallback.normalized()

    fallback = global_transform.basis.x - surface_up * global_transform.basis.x.dot(surface_up)
    if fallback.length_squared() > 0.01:
        return fallback.normalized()

    return Vector3.FORWARD


func _align_body_to_surface(new_up: Vector3, preferred_forward: Vector3) -> void:
    var forward := preferred_forward - new_up * preferred_forward.dot(new_up)

    if forward.length_squared() < 0.01:
        forward = Vector3.UP - new_up * Vector3.UP.dot(new_up)

    if forward.length_squared() < 0.01:
        forward = global_transform.basis.x - new_up * global_transform.basis.x.dot(new_up)

    forward = forward.normalized()
    var right := forward.cross(new_up).normalized()
    var target_basis := Basis(right, new_up, -forward).orthonormalized()

    var current_rotation := global_transform.basis.get_rotation_quaternion()
    var target_rotation := target_basis.get_rotation_quaternion()
    var weight := 1.0 - exp(-reorientation_speed * get_physics_process_delta_time())

    global_transform.basis = Basis(current_rotation.slerp(target_rotation, weight)).orthonormalized()


func _update_surface_name() -> void:
    var name := get_surface_name()
    if name != _last_surface_name:
        _last_surface_name = name


func get_surface_name() -> String:
    if surface_up.dot(Vector3.UP) > 0.84:
        return "FLOOR"

    if surface_up.dot(Vector3.DOWN) > 0.84:
        return "CEILING"

    return "WALL"
