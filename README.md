# GD-TEST — Surface Walker Prototype

Prototype for Godot 4.7.2.

The build is intentionally asset-free: clone or download the repository, import the project in Godot, and press Play.

## Prototype

- First-person 3D movement.
- Mouse look with captured cursor.
- Floor, four walls and a ceiling form a simple test room.
- Walk into a wall and the player's local up rotates to that wall normal.
- The wall becomes the new floor: gravity, movement and camera orientation follow the new surface.
- The controller can continue around another plane, including the ceiling.
- No external assets or plugins are required.

## Controls

WASD — move  
Shift — sprint  
Mouse — look  
Esc — release the mouse  
Left mouse — capture the mouse again

## Project structure

~~~text
project.godot
scenes/
  main.tscn
  player.tscn
scripts/
  main.gd
  player.gd
~~~

## Architecture

Player is a CharacterBody3D. Its up_direction is dynamic instead of being permanently world-up.

A physics probe detects the next surface. Its collision normal becomes target_surface_up, then the controller smoothly reorients the player so the new plane behaves like the floor.

Movement is projected onto the current surface plane:

~~~text
tangent_velocity = velocity - surface_up * velocity.dot(surface_up)
~~~

Godot move_and_slide() then performs the normal CharacterBody3D collision handling with that dynamic up direction.

## Tuning

Open scripts/player.gd and adjust:

- move_speed
- sprint_multiplier
- gravity
- surface_probe_distance
- reorientation_speed
- mouse_sensitivity

This is the base layer for the larger changing-planes / non-Euclidean-feeling prototype.
