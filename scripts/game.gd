extends Node3D

@onready var player = $Player
@onready var room_generator: RoomGenerator = $RoomGenerator
@onready var info: Label = $HUD/Info
@onready var seed_label: Label = $HUD/Seed

var room_seed: int


func _ready() -> void:
    _setup_environment()

    room_seed = Time.get_ticks_usec() ^ randi()
    room_generator.generate_room(room_seed)

    player.global_position = room_generator.get_spawn_position()
    player.surface_up = Vector3.UP
    player.target_surface_up = Vector3.UP
    player.look_forward = Vector3.FORWARD

    seed_label.text = "SEED  %d" % room_seed


func _process(_delta: float) -> void:
    info.text = (
        "WASD — move    SHIFT — sprint\n"
        + "Mouse — look    ESC — release cursor\n\n"
        + "SURFACE: "
        + player.get_surface_name()
        + "\nNORMAL: "
        + _format_vector(player.surface_up)
        + "\nROOM: "
        + room_generator.get_room_description()
    )


func _setup_environment() -> void:
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.008, 0.012, 0.022)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.52, 0.56, 0.68)
    environment.ambient_light_energy = 0.85

    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    add_child(world_environment)

    var sun := DirectionalLight3D.new()
    sun.name = "Sun"
    sun.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
    sun.light_energy = 1.25
    sun.shadow_enabled = true
    add_child(sun)

    var fill := OmniLight3D.new()
    fill.name = "FillLight"
    fill.position = Vector3(0, 5, 0)
    fill.omni_range = 30.0
    fill.light_energy = 2.2
    fill.light_color = Color(0.48, 0.62, 1.0)
    add_child(fill)


func _format_vector(value: Vector3) -> String:
    return "(%+.1f, %+.1f, %+.1f)" % [value.x, value.y, value.z]
