extends Control

@onready var start_button: Button = $Center/Panel/VBox/StartButton
@onready var status_label: Label = $Center/Panel/VBox/Status


func _ready() -> void:
    start_button.grab_focus()
    status_label.text = "EVERY ROOM IS DIFFERENT"


func _on_start_button_pressed() -> void:
    start_button.disabled = true
    status_label.text = "GENERATING RANDOM ROOM..."

    var result := get_tree().change_scene_to_file("res://scenes/game.tscn")
    if result != OK:
        start_button.disabled = false
        status_label.text = "FAILED TO LOAD GAME"
