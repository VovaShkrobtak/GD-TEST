extends CharacterBody3D

## Surface-walking first-person controller.
##
## Surface changes are driven by real CharacterBody3D collision normals.
## This is much more reliable at corners than guessing the next plane with
## a few forward/side raycasts.
##
## The important separation is:
##   surface_up  -> physics orientation / gravity
##   look_forward -> player's yaw, independent from the body's changing basis
##   view_pivot  -> camera pitch only
##
## Because yaw is stored separately, reorienting the body between floor,
## wall and ceiling cannot accidentally reset the camera's horizontal view.

@export_category("Movement")
@export var move_speed: float = 5.5
@export var sprint_multiplier: float = 1.65
@export var acceleration: float = 24.0
@export var braking: float = 30.0
@export var gravity: float = 18.0

@export_category("Surface walking")
@export var reorientation_speed: float = 8.0
@export_range(0.0, 1.0, 0.01) var surface_change_dot: float = 0.86
@export var surface_contact_snap: float = 0.28

@export_category("Look")
@export var mouse_sensitivity: float = 0.0023
@export var max_pitch: float = 1.45

@onready var view_pivot: Node3D = $ViewPivot


var surface_up: Vector3 = Vector3.UP
var target_surface_up: Vector3 = Vector3.UP

# Horizontal view direction in world space. This is deliberately NOT read
# back from transform.basis, because transform.basis is continuously rotated
# while changing surfaces.
var look_forward: Vector3 = Vector3.FORWARD

var pitch: float = 0.0
var _mouse_captured := true
var _last_surface_name := "FLOOR"


func _ready() -> void:
    up_direction = surface_up
    floor_max_angle = PI * 0.5
    floor_snap_length = surface_contact_snap
    safe_margin = 0.03

    # Start with a clean FPS orientation:
    # forward = -Z, up = +Y, right = +X.
    look_forward = Vector3.FORWARD
    _rebuild_body_basis()

    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    view_pivot.rotation.x = pitch


func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and _mouse_captured:
        # Yaw is around the player's CURRENT surface normal, not world Y.
        look_forward = look_forward.rotated(
            surface_up,
            -event.screen_relative.x * mouse_sensitivity
        ).normalized()

        # Keep the view exactly tangent to the current plane.
        _project_look_onto_surface()

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
    # Use the surface from the previous frame for this movement step.
    up_direction = surface_up

    _project_look_onto_surface()

    var input_2d := Vector2(
        float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
        float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
    )

    if input_2d.length_squared() > 1.0:
        input_2d = input_2d.normalized()

    var forward := look_forward
    var right := look_forward.cross(surface_up).normalized()

    var desired_direction := right * input_2d.x + forward * input_2d.y
    desired_direction = _project_on_plane(desired_direction, surface_up)

    var on_support := is_on_floor()

    if desired_direction.length_squared() > 0.0001:
        desired_direction = desired_direction.normalized()

        var speed := move_speed
        if Input.is_key_pressed(KEY_SHIFT):
            speed *= sprint_multiplier

        var planar_velocity := _project_on_plane(velocity, surface_up)
        planar_velocity = planar_velocity.move_toward(
            desired_direction * speed,
            acceleration * delta
        )

        var normal_velocity := velocity.dot(surface_up)

        if on_support:
            normal_velocity = minf(normal_velocity, 0.0)
        else:
            normal_velocity -= gravity * delta

        velocity = planar_velocity + surface_up * normal_velocity

    else:
        var planar_velocity := _project_on_plane(velocity, surface_up)
        planar_velocity = planar_velocity.move_toward(
            Vector3.ZERO,
            braking * delta
        )

        var normal_velocity := velocity.dot(surface_up)

        if on_support:
            normal_velocity = 0.0
        else:
            normal_velocity -= gravity * delta

        velocity = planar_velocity + surface_up * normal_velocity

    # The actual collision happens first.
    move_and_slide()

    # Now inspect what we REALLY hit this frame. This catches:
    #   floor -> wall
    #   wall -> wall
    #   wall -> ceiling
    #   ceiling -> wall
    # without relying on a particular camera/basis direction.
    var collision_normal := _find_transition_normal()

    if collision_normal.length_squared() > 0.0001:
        _set_target_surface(collision_normal)

    # Move the body's orientation toward the new plane.
    _update_surface_orientation(delta)

    # Once the new surface is current, let CharacterBody3D keep us attached.
    up_direction = surface_up
    floor_snap_length = surface_contact_snap

    if is_on_floor():
        apply_floor_snap()

    _update_surface_name()


func _find_transition_normal() -> Vector3:
    if get_slide_collision_count() == 0:
        return Vector3.ZERO

    var best_normal := Vector3.ZERO
    var best_score := 2.0

    for index in range(get_slide_collision_count()):
        var collision := get_slide_collision(index)
        var normal := collision.get_normal().normalized()

        # Ignore surfaces that are basically the plane we're already walking on.
        var same_surface := normal.dot(surface_up)

        if same_surface >= surface_change_dot:
            continue

        # Prefer the surface most different from our current up direction.
        # At a corner, either neighboring plane is a valid transition target.
        if same_surface < best_score:
            best_score = same_surface
            best_normal = normal

    return best_normal


func _set_target_surface(new_normal: Vector3) -> void:
    new_normal = new_normal.normalized()

    if new_normal.dot(surface_up) >= surface_change_dot:
        return

    # Transport the stored view direction across the corner BEFORE changing
    # surface_up. This preserves where the player was looking instead of
    # recalculating the camera from the body's already-rotated basis.
    look_forward = _transport_vector(
        look_forward,
        surface_up,
        new_normal
    )

    target_surface_up = new_normal


func _update_surface_orientation(delta: float) -> void:
    var old_up := surface_up

    var blend := 1.0 - exp(-reorientation_speed * delta)
    surface_up = surface_up.slerp(
        target_surface_up,
        blend
    ).normalized()

    up_direction = surface_up
    _project_look_onto_surface()

    # Rebuild the body basis from our independent look direction + surface up.
    # No camera yaw is ever recovered from the changing transform.
    _rebuild_body_basis()

    # When we are extremely close to the target, finish exactly on it.
    if surface_up.dot(target_surface_up) > 0.9999:
        surface_up = target_surface_up
        up_direction = surface_up
        _project_look_onto_surface()
        _rebuild_body_basis()

    # Avoid unused-variable warnings while keeping this useful during
    # debugging of abrupt normal changes.
    if old_up.dot(surface_up) < 0.0:
        surface_up = target_surface_up
        up_direction = surface_up
        _project_look_onto_surface()
        _rebuild_body_basis()


func _rebuild_body_basis() -> void:
    var forward := _project_on_plane(look_forward, surface_up)

    if forward.length_squared() < 0.0001:
        forward = _fallback_forward(surface_up)

    forward = forward.normalized()
    look_forward = forward

    var right := forward.cross(surface_up)

    if right.length_squared() < 0.0001:
        right = _fallback_right(surface_up, forward)

    right = right.normalized()

    # Basis axes:
    # X = right
    # Y = surface up
    # Z = -forward
    global_transform.basis = Basis(
        right,
        surface_up,
        -forward
    ).orthonormalized()


func _project_look_onto_surface() -> void:
    var projected := _project_on_plane(look_forward, surface_up)

    if projected.length_squared() > 0.0001:
        look_forward = projected.normalized()
    else:
        look_forward = _fallback_forward(surface_up)


func _project_on_plane(direction: Vector3, normal: Vector3) -> Vector3:
    return direction - normal * direction.dot(normal)


func _transport_vector(
    direction: Vector3,
    from_normal: Vector3,
    to_normal: Vector3
) -> Vector3:
    var from_n := from_normal.normalized()
    var to_n := to_normal.normalized()

    var dot_value := clampf(from_n.dot(to_n), -1.0, 1.0)

    if dot_value > 0.99999:
        return _project_on_plane(direction, to_n).normalized()

    var axis := from_n.cross(to_n)

    if axis.length_squared() < 0.00001:
        # 180-degree flip. Pick any axis perpendicular to the old normal.
        axis = from_n.cross(Vector3.RIGHT)

        if axis.length_squared() < 0.00001:
            axis = from_n.cross(Vector3.FORWARD)

        axis = axis.normalized()
        return _project_on_plane(
            direction.rotated(axis, PI),
            to_n
        ).normalized()

    axis = axis.normalized()
    var angle := acos(dot_value)

    return _project_on_plane(
        direction.rotated(axis, angle),
        to_n
    ).normalized()


func _fallback_forward(normal: Vector3) -> Vector3:
    var candidate := _project_on_plane(Vector3.FORWARD, normal)

    if candidate.length_squared() > 0.0001:
        return candidate.normalized()

    candidate = _project_on_plane(Vector3.RIGHT, normal)

    if candidate.length_squared() > 0.0001:
        return candidate.normalized()

    candidate = _project_on_plane(Vector3.UP, normal)

    if candidate.length_squared() > 0.0001:
        return candidate.normalized()

    return Vector3.FORWARD


func _fallback_right(normal: Vector3, forward: Vector3) -> Vector3:
    var candidate := forward.cross(normal)

    if candidate.length_squared() > 0.0001:
        return candidate.normalized()

    candidate = normal.cross(Vector3.RIGHT)

    if candidate.length_squared() > 0.0001:
        return candidate.normalized()

    return Vector3.RIGHT


func _update_surface_name() -> void:
    var surface_label := get_surface_name()

    if surface_label != _last_surface_name:
        _last_surface_name = surface_label


func get_surface_name() -> String:
    if surface_up.dot(Vector3.UP) > 0.84:
        return "FLOOR"

    if surface_up.dot(Vector3.DOWN) > 0.84:
        return "CEILING"

    return "WALL"
