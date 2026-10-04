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

@export_category("Head Bob")
@export var bob_enabled: bool = true
@export var bob_frequency: float = 1.8
@export var bob_vertical_amplitude: float = 0.055
@export var bob_lateral_amplitude: float = 0.035
@export var bob_roll_amplitude: float = 0.025
@export var bob_smoothing: float = 10.0
@export var sprint_bob_multiplier: float = 1.08

@onready var view_pivot: Node3D = $ViewPivot
@onready var camera: Camera3D = $ViewPivot/Camera3D

const CAMERA_REST_POSITION := Vector3(0.0, 1.5, 0.0)

var bob_phase: float = 0.0
var bob_amount: float = 0.0
var bob_position_offset := Vector3.ZERO
var bob_roll: float = 0.0


var surface_up: Vector3 = Vector3.UP
var target_surface_up: Vector3 = Vector3.UP

# Horizontal view direction in world space. This is deliberately NOT read
# back from transform.basis, because transform.basis is continuously rotated
# while changing surfaces.
var look_forward: Vector3 = Vector3.FORWARD

var pitch: float = 0.0
var _mouse_captured := true
var _last_surface_name := "FLOOR"

# Prevent the controller from switching back and forth between two normals
# while the capsule is physically touching a 90-degree corner.
var _surface_transition_lock: float = 0.0
@export var surface_transition_lock_time: float = 0.38


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
    if _surface_transition_lock > 0.0:
        _surface_transition_lock = maxf(
            0.0,
            _surface_transition_lock - delta
        )

    # Use the surface from the previous frame for this movement step.
    up_direction = surface_up

    _project_look_onto_surface()

    var input_2d := Vector2(
        float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
        float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
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
    var velocity_before_collision := velocity
    move_and_slide()

    # Keep the gait camera driven by the motion that existed immediately
    # before collision resolution.
    var planar_speed := _project_on_plane(
        velocity_before_collision,
        surface_up
    ).length()

    # Now inspect what we REALLY hit this frame. This catches:
    #   floor -> wall
    #   wall -> wall
    #   wall -> ceiling
    #   ceiling -> wall
    # without relying on a particular camera/basis direction.
    var collision_normal := _find_transition_normal(velocity_before_collision)

    if collision_normal.length_squared() > 0.0001:
        _set_target_surface(collision_normal)

    # Move the body's orientation toward the new plane.
    _update_surface_orientation(delta)

    # Once the new surface is current, let CharacterBody3D keep us attached.
    up_direction = surface_up
    floor_snap_length = surface_contact_snap

    if is_on_floor():
        apply_floor_snap()

    _update_head_bob(delta, planar_speed, is_on_floor())
    _update_surface_name()


func _find_transition_normal(approach_velocity: Vector3) -> Vector3:
    if get_slide_collision_count() == 0:
        return Vector3.ZERO

    var best_normal := Vector3.ZERO
    var best_score := -1000000.0

    var approach := approach_velocity.normalized()

    for index in range(get_slide_collision_count()):
        var collision := get_slide_collision(index)
        var normal := collision.get_normal().normalized()

        # Ignore surfaces that are basically the plane we're already walking on.
        var same_surface := normal.dot(surface_up)
        if same_surface >= surface_change_dot:
            continue

        # A genuine transition surface should be in front of our motion.
        # This rejects side contacts that otherwise compete with the actual
        # wall/ceiling we're walking into.
        var impact := 0.0
        if approach_velocity.length_squared() > 0.04:
            impact = maxf(0.0, -approach.dot(normal))

        # At a 90-degree corner the two normals can be equally valid.
        # The first selected normal gets locked for a short time, preventing
        # frame-to-frame oscillation between the two surfaces.
        var difference := 1.0 - same_surface

        # Strongly prefer an actual head-on transition; retain difference as
        # a tie-breaker when approaching a corner diagonally.
        var score := impact * 4.0 + difference

        if approach_velocity.length_squared() <= 0.04:
            score = difference

        if score > best_score:
            best_score = score
            best_normal = normal

    return best_normal


func _set_target_surface(new_normal: Vector3) -> void:
    new_normal = new_normal.normalized()

    if new_normal.dot(surface_up) >= surface_change_dot:
        return

    # During the short corner-transition window, accept only the normal that
    # belongs to the transition already in progress. This eliminates the
    # classic wall/corner/ceiling camera jitter.
    if _surface_transition_lock > 0.0:
        if target_surface_up.dot(new_normal) < 0.96:
            return
        return

    _surface_transition_lock = surface_transition_lock_time

    # Transport the stored view direction across the corner BEFORE changing
    # surface_up. This preserves where the player was looking instead of
    # recalculating the camera from the body's already-rotated basis.
    look_forward = _transport_vector(
        look_forward,
        surface_up,
        new_normal
    )

    target_surface_up = new_normal


func _update_head_bob(
    delta: float,
    planar_speed: float,
    grounded: bool
) -> void:
    if not bob_enabled:
        bob_amount = move_toward(bob_amount, 0.0, bob_smoothing * delta)
        bob_position_offset = bob_position_offset.lerp(
            Vector3.ZERO,
            1.0 - exp(-bob_smoothing * delta)
        )
        bob_roll = lerpf(
            bob_roll,
            0.0,
            1.0 - exp(-bob_smoothing * delta)
        )
    else:
        var speed_ratio := clampf(planar_speed / move_speed, 0.0, 1.75)
        var target_amount := 0.0

        if grounded and planar_speed > 0.25:
            target_amount = clampf(speed_ratio, 0.0, 1.0)

        bob_amount = lerpf(
            bob_amount,
            target_amount,
            1.0 - exp(-bob_smoothing * delta)
        )

        if target_amount > 0.0:
            var sprint_factor := 1.0
            if Input.is_key_pressed(KEY_SHIFT):
                sprint_factor = sprint_bob_multiplier

            var frequency := bob_frequency * lerpf(
                0.88,
                1.22,
                clampf(speed_ratio, 0.0, 1.0)
            ) * sprint_factor

            bob_phase += TAU * frequency * delta

            # Two vertical peaks per gait cycle and a slower side-to-side
            # sway create a subtle human head movement rather than a sine-wave
            # camera attached directly to velocity.
            var vertical := (0.5 - 0.5 * cos(bob_phase * 2.0))
            vertical -= 0.28

            var lateral := sin(bob_phase)
            var roll := sin(bob_phase) * bob_roll_amplitude
            roll += sin(bob_phase * 2.0) * bob_roll_amplitude * 0.35

            bob_position_offset = Vector3(
                lateral * bob_lateral_amplitude * bob_amount,
                vertical * bob_vertical_amplitude * bob_amount,
                0.0
            )

            bob_roll = roll * bob_amount
        else:
            bob_position_offset = bob_position_offset.lerp(
                Vector3.ZERO,
                1.0 - exp(-bob_smoothing * delta)
            )
            bob_roll = lerpf(
                bob_roll,
                0.0,
                1.0 - exp(-bob_smoothing * delta)
            )

    camera.position = CAMERA_REST_POSITION + bob_position_offset
    camera.rotation.z = bob_roll


func _update_surface_orientation(delta: float) -> void:
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
