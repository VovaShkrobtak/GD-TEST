class_name RoomGenerator

extends Node3D

## Procedural room generator.
##
## One seed generates one deterministic room. A new random seed is created
## by game.gd every time the player presses START from the main menu.
##
## The perimeter is always six-sided so the surface-walking controller has
## floor, walls and ceiling to work with. Interior structures are random
## boxes placed on the floor; their sides and tops become additional
## walkable surfaces.

@export_category("Room Size")
@export var min_width: int = 14
@export var max_width: int = 30
@export var min_depth: int = 14
@export var max_depth: int = 30
@export var min_height: int = 7
@export var max_height: int = 14
@export var wall_thickness: float = 0.7

@export_category("Interior Generation")
@export var min_structures: int = 2
@export var max_structures: int = 9
@export var min_structure_size: float = 1.4
@export var max_structure_size: float = 4.5
@export var min_structure_height: float = 1.5
@export var max_structure_height: float = 6.0
@export var spawn_clear_radius: float = 3.2

var _rng := RandomNumberGenerator.new()
var _generated_nodes: Array[Node] = []

var room_width: float = 20.0
var room_depth: float = 20.0
var room_height: float = 10.0
var generated_seed: int = 0
var _spawn_position := Vector3(0, 0.05, 0)


func generate_room(seed_value: int) -> void:
    _clear_previous_room()

    generated_seed = seed_value
    _rng.seed = seed_value

    room_width = float(_rng.randi_range(min_width, max_width))
    room_depth = float(_rng.randi_range(min_depth, max_depth))
    room_height = float(_rng.randi_range(min_height, max_height))

    _build_perimeter()
    _build_interior_structures()

    _spawn_position = _find_spawn_position()


func _clear_previous_room() -> void:
    for node in _generated_nodes:
        if is_instance_valid(node):
            node.queue_free()

    _generated_nodes.clear()


func _build_perimeter() -> void:
    var floor_color := _random_room_color()
    var wall_color := _random_room_color()
    var side_color := _random_room_color()
    var ceiling_color := _random_room_color()

    # Floor top is Y = 0.
    _make_box(
        "Floor",
        Vector3(0.0, -wall_thickness * 0.5, 0.0),
        Vector3(room_width, wall_thickness, room_depth),
        floor_color
    )

    _make_box(
        "Ceiling",
        Vector3(0.0, room_height + wall_thickness * 0.5, 0.0),
        Vector3(room_width, wall_thickness, room_depth),
        ceiling_color
    )

    _make_box(
        "FrontWall",
        Vector3(0.0, room_height * 0.5, -room_depth * 0.5 - wall_thickness * 0.5),
        Vector3(room_width, room_height + wall_thickness, wall_thickness),
        wall_color
    )

    _make_box(
        "BackWall",
        Vector3(0.0, room_height * 0.5, room_depth * 0.5 + wall_thickness * 0.5),
        Vector3(room_width, room_height + wall_thickness, wall_thickness),
        side_color
    )

    _make_box(
        "LeftWall",
        Vector3(-room_width * 0.5 - wall_thickness * 0.5, room_height * 0.5, 0.0),
        Vector3(wall_thickness, room_height + wall_thickness, room_depth),
        side_color
    )

    _make_box(
        "RightWall",
        Vector3(room_width * 0.5 + wall_thickness * 0.5, room_height * 0.5, 0.0),
        Vector3(wall_thickness, room_height + wall_thickness, room_depth),
        wall_color
    )


func _build_interior_structures() -> void:
    var structure_count := _rng.randi_range(min_structures, max_structures)

    for index in range(structure_count):
        var placed := false

        for _attempt in range(24):
            var size_x := _rng.randf_range(
                min_structure_size,
                minf(max_structure_size, room_width * 0.28)
            )
            var size_z := _rng.randf_range(
                min_structure_size,
                minf(max_structure_size, room_depth * 0.28)
            )
            var height := _rng.randf_range(
                min_structure_height,
                minf(max_structure_height, room_height - 1.5)
            )

            var margin_x := size_x * 0.5 + 1.0
            var margin_z := size_z * 0.5 + 1.0

            var x := _rng.randf_range(
                -room_width * 0.5 + margin_x,
                room_width * 0.5 - margin_x
            )
            var z := _rng.randf_range(
                -room_depth * 0.5 + margin_z,
                room_depth * 0.5 - margin_z
            )

            if Vector2(x, z).length() < spawn_clear_radius:
                continue

            var structure_position := Vector3(
                x,
                height * 0.5,
                z
            )

            # Keep modules visually and physically separate enough that they
            # do not accidentally create tiny impossible crevices.
            if _overlaps_existing_structure(
                structure_position,
                Vector3(size_x, height, size_z)
            ):
                continue

            var material := _random_structure_material()
            _make_box(
                "Structure_%02d" % index,
                structure_position,
                Vector3(size_x, height, size_z),
                material
            )

            placed = true
            break

        if not placed:
            continue


func _overlaps_existing_structure(
    center: Vector3,
    size: Vector3
) -> bool:
    var new_min := Vector3(
        center.x - size.x * 0.5,
        0.0,
        center.z - size.z * 0.5
    )
    var new_max := Vector3(
        center.x + size.x * 0.5,
        size.y,
        center.z + size.z * 0.5
    )

    for node in _generated_nodes:
        if not is_instance_valid(node):
            continue
        if not node.name.begins_with("Structure_"):
            continue

        var existing_body := node as StaticBody3D
        if existing_body == null:
            continue

        var existing_size: Vector3 = existing_body.get_meta("box_size", Vector3.ZERO)
        var existing_center := existing_body.position

        var existing_min := Vector3(
            existing_center.x - existing_size.x * 0.5,
            0.0,
            existing_center.z - existing_size.z * 0.5
        )
        var existing_max := Vector3(
            existing_center.x + existing_size.x * 0.5,
            existing_size.y,
            existing_center.z + existing_size.z * 0.5
        )

        var intersects_x := new_min.x < existing_max.x and new_max.x > existing_min.x
        var intersects_z := new_min.z < existing_max.z and new_max.z > existing_min.z

        if intersects_x and intersects_z:
            return true

    return false


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
    body.set_meta("box_size", box_size)
    add_child(body)
    _generated_nodes.append(body)

    var mesh := MeshInstance3D.new()
    mesh.name = "Mesh"
    var box_mesh := BoxMesh.new()
    box_mesh.size = box_size
    box_mesh.material = material
    mesh.mesh = box_mesh
    body.add_child(mesh)

    var collision := CollisionShape3D.new()
    collision.name = "Collision"
    var box_shape := BoxShape3D.new()
    box_shape.size = box_size
    collision.shape = box_shape
    body.add_child(collision)


func _find_spawn_position() -> Vector3:
    # Start slightly above the floor so the CharacterBody3D settles cleanly.
    return Vector3(
        _rng.randf_range(-1.0, 1.0),
        0.06,
        _rng.randf_range(-1.0, 1.0)
    )


func _random_room_color() -> StandardMaterial3D:
    var choices := [
        Color(0.12, 0.16, 0.22),
        Color(0.17, 0.20, 0.27),
        Color(0.19, 0.15, 0.25),
        Color(0.12, 0.22, 0.25),
        Color(0.22, 0.18, 0.14)
    ]
    return _material(choices[_rng.randi_range(0, choices.size() - 1)], 0.78)


func _random_structure_material() -> StandardMaterial3D:
    var choices := [
        Color(0.33, 0.42, 0.60),
        Color(0.46, 0.30, 0.52),
        Color(0.25, 0.45, 0.43),
        Color(0.56, 0.36, 0.24),
        Color(0.32, 0.36, 0.42),
        Color(0.60, 0.24, 0.28)
    ]
    return _material(choices[_rng.randi_range(0, choices.size() - 1)], 0.62)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    material.metallic = _rng.randf_range(0.0, 0.18)
    return material


func get_spawn_position() -> Vector3:
    return _spawn_position


func get_room_description() -> String:
    return "%dm × %dm × %dm" % [
        roundi(room_width),
        roundi(room_depth),
        roundi(room_height)
    ]
