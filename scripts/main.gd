extends Node3D

@onready var player: CharacterBody3D = $Player
@onready var info: Label = $HUD/Info

var floor_material: StandardMaterial3D
var wall_material: StandardMaterial3D
var side_material: StandardMaterial3D
var ceiling_material: StandardMaterial3D
var accent_material: StandardMaterial3D


func _ready() -> void:
    _setup_environment()
    _build_room()


func _process(_delta: float) -> void:
    if is_instance_valid(player):
        info.text = (
            "WASD — move    SHIFT — sprint\n"
            + "Mouse — look    ESC — release cursor\n\n"
            + "SURFACE: "
            + player.get_surface_name()
            + "\nNORMAL: "
            + _format_vector(player.surface_up)
        )


func _setup_environment() -> void:
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.012, 0.018, 0.032)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.46, 0.5, 0.58)
    environment.ambient_light_energy = 0.85
    environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    add_child(world_environment)

    var sun := DirectionalLight3D.new()
    sun.name = "Sun"
    sun.rotation_degrees = Vector3(-48.0, -28.0, 0.0)
    sun.light_energy = 1.45
    sun.shadow_enabled = true
    add_child(sun)

    var fill := OmniLight3D.new()
    fill.name = "FillLight"
    fill.position = Vector3(0, 5, 1)
    fill.omni_range = 24.0
    fill.light_energy = 3.2
    fill.light_color = Color(0.48, 0.62, 1.0)
    add_child(fill)

    floor_material = _material(Color(0.13, 0.16, 0.21), 0.72)
    wall_material = _material(Color(0.16, 0.24, 0.38), 0.68)
    side_material = _material(Color(0.12, 0.31, 0.26), 0.68)
    ceiling_material = _material(Color(0.27, 0.18, 0.30), 0.8)
    accent_material = _material(Color(0.75, 0.32, 0.92), 0.48)


func _build_room() -> void:
    _make_box("Floor", Vector3(0, -0.5, 0), Vector3(24, 1, 24), floor_material)
    _make_box("Ceiling", Vector3(0, 12.5, 0), Vector3(24, 1, 24), ceiling_material)

    _make_box("FrontWall", Vector3(0, 6, -11.5), Vector3(24, 13, 1), wall_material)
    _make_box("BackWall", Vector3(0, 6, 11.5), Vector3(24, 13, 1), wall_material)

    _make_box("LeftWall", Vector3(-11.5, 6, 0), Vector3(1, 13, 24), side_material)
    _make_box("RightWall", Vector3(11.5, 6, 0), Vector3(1, 13, 24), side_material)

    _make_box("FrontAccent", Vector3(0, 0.02, -10.92), Vector3(22, 0.08, 0.08), accent_material)
    _make_box("LeftAccent", Vector3(-10.92, 0.02, 0), Vector3(0.08, 0.08, 22), accent_material)
    _make_box("RightAccent", Vector3(10.92, 0.02, 0), Vector3(0.08, 0.08, 22), accent_material)


func _make_box(
    box_name: String,
    box_position: Vector3,
    box_size: Vector3,
    material: StandardMaterial3D
) -> void:
    var body := StaticBody3D.new()
    body.name = box_name
    body.position = box_position
    body.collision_layer = 1
    body.collision_mask = 1
    add_child(body)

    var mesh := MeshInstance3D.new()
    var box_mesh := BoxMesh.new()
    box_mesh.size = box_size
    box_mesh.material = material
    mesh.mesh = box_mesh
    body.add_child(mesh)

    var collision := CollisionShape3D.new()
    var box_shape := BoxShape3D.new()
    box_shape.size = box_size
    collision.shape = box_shape
    body.add_child(collision)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    material.metallic = 0.05
    return material


func _format_vector(value: Vector3) -> String:
    return "(%+.1f, %+.1f, %+.1f)" % [value.x, value.y, value.z]
