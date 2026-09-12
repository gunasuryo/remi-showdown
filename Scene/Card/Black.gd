#extends Sprite2D
#
#var count:int = 0
#func _input(event):
#	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
#		if get_rect().has_point(to_local(event.position)):
#			count += 1
#			print("Black card clicked")
#			print(count)
