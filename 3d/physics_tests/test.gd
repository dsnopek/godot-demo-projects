class_name Test
extends Node


signal wait_done()

var _timer
var _timer_started = false

var _wait_physics_ticks_counter = 0

var _drawn_nodes = []


func _physics_process(_delta):
	if (_wait_physics_ticks_counter > 0):
		_wait_physics_ticks_counter -= 1
		if (_wait_physics_ticks_counter == 0):
			emit_signal("wait_done")


func add_sphere(pos, radius, color):
	var sphere = MeshInstance.new()

	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = radius
	sphere_mesh.height = radius * 2.0
	sphere.mesh = sphere_mesh

	var material = SpatialMaterial.new()
	material.flags_unshaded = true
	material.albedo_color = color
	sphere.material_override = material

	_drawn_nodes.push_back(sphere)
	add_child(sphere)

	sphere.global_transform.origin = pos


func add_shape(shape, transform, color):
	var collision = CollisionShape.new()
	collision.shape = shape

	_drawn_nodes.push_back(collision)
	add_child(collision)

	var mesh_instance = collision.get_child(0)
	var material = SpatialMaterial.new()
	material.flags_unshaded = true
	material.albedo_color = color
	mesh_instance.material_override = material

	collision.global_transform = transform


func clear_drawn_nodes():
	for node in _drawn_nodes:
		node.queue_free()
	_drawn_nodes.clear()


func create_rigidbody_box(size):
	var template_shape = BoxShape.new()
	template_shape.extents = 0.5 * size

	var template_collision = CollisionShape.new()
	template_collision.shape = template_shape

	var template_body = RigidBody.new()
	template_body.add_child(template_collision)

	return template_body


func start_timer(timeout):
	if _timer == null:
		_timer = Timer.new()
		_timer.one_shot = true
		add_child(_timer)
		_timer.connect("timeout", self, "_on_timer_done")
	else:
		cancel_timer()

	_timer.start(timeout)
	_timer_started = true

	return _timer


func cancel_timer():
	if _timer_started:
		_timer.paused = true
		_timer.emit_signal("timeout")
		_timer.paused = false


func is_timer_canceled():
	return _timer.paused


func wait_for_physics_ticks(tick_count):
	_wait_physics_ticks_counter = tick_count
	return self


func _on_timer_done():
	_timer_started = false
