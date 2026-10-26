extends Control
## Représentation géométrique uniquement : aucun moteur physique.

const FIXED_COLOR := Color(0.25, 0.33, 0.44)
const MOBILE_COLOR := Color(0.06, 0.45, 0.78)
const BACKGROUND_COLOR := Color(0.95, 0.96, 0.98)
const MAX_ANGLE := PI / 4.0
const PERIOD_SECONDS := 6.0
const MAX_TRAVEL := 0.65
enum Joint { PIVOT, SLIDER, FIXED, PIVOT_X, CYLINDRICAL, SCREW, SPHERICAL, ANNULAR, FINGER, PLANE, LINE, POINT }
const CATALOG = preload("res://scripts/joint_catalog.gd").ENTRIES
const SCREW_PITCH := 0.8
const POINTER_COLOR := Color(0.95, 0.48, 0.05)
const ORBIT_SENSITIVITY := 0.008
const CAMERA_TARGET := Vector3(0.4, 0.0, 0.0)
const AXIS_COLORS := [Color(0.8, 0.16, 0.16), Color(0.12, 0.52, 0.23), Color(0.12, 0.34, 0.85)]

@onready var diagram: Control = $Margin/Layout/Views/View2D/Diagram
@onready var viewport_3d: SubViewport = $Margin/Layout/Views/View3D/ViewportContainer/Viewport
@onready var view_3d: SubViewportContainer = $Margin/Layout/Views/View3D/ViewportContainer
@onready var animate_button: Button = $Margin/Layout/Controls/AnimateButton
@onready var test_rz: CheckButton = $Margin/Layout/Controls/TestRz
@onready var joint_list: OptionButton = $Margin/Layout/JointList

var animating: bool = false
var phase: float = 0.0
var angle: float = 0.0
var mobile_3d: Node3D
var camera_3d: Camera3D
var orbit_dragging: bool = false
var orbit_yaw: float = 0.0
var orbit_pitch: float = 0.0
var orbit_distance: float = 0.0
var axes_overlay: Control
var selected_joint: int = Joint.PIVOT
var travel: float = 0.0
var model_3d: Node3D
var motion_translation := Vector3.ZERO
var motion_rotation := Vector3.ZERO


func _ready() -> void:
	_build_3d_view()
	for index in range(CATALOG.size()):
		if index == Joint.PIVOT:
			continue
		joint_list.add_item(CATALOG[index].name, index)
	joint_list.item_selected.connect(_select_joint)
	# Un calque transparent garde le repère lisible devant le rendu 3D.
	axes_overlay = Control.new()
	view_3d.add_child(axes_overlay)
	axes_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	axes_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	axes_overlay.draw.connect(_draw_3d_axes)
	axes_overlay.resized.connect(axes_overlay.queue_redraw)
	animate_button.pressed.connect(_toggle_animation)
	test_rz.toggled.connect(_on_test_rz_toggled)
	diagram.resized.connect(queue_redraw)
	diagram.item_rect_changed.connect(queue_redraw)
	set_process(false)
	_select_joint(0)


func _toggle_animation() -> void:
	if selected_joint == Joint.FIXED:
		return
	animating = not animating
	animate_button.text = "Arrêter" if animating else "Animer"
	set_process(animating)


func _select_joint(index: int) -> void:
	selected_joint = joint_list.get_item_id(index)
	animating = false
	orbit_dragging = false
	set_process(false)
	animate_button.text = "Animer"
	phase = 0.0
	angle = 0.0
	travel = 0.0
	motion_translation = Vector3.ZERO
	motion_rotation = Vector3.ZERO
	for child in model_3d.get_children():
		model_3d.remove_child(child)
		child.queue_free()
	match selected_joint:
		Joint.PIVOT: _build_pivot_model(model_3d)
		Joint.SLIDER: _build_slider_model(model_3d)
		_: _build_catalog_model(model_3d)
	var entry: Dictionary = CATALOG[selected_joint]
	test_rz.visible = selected_joint in [Joint.SPHERICAL, Joint.FINGER]
	$Margin/Layout/Subtitle.text = "%s — centre %s, %s" % [entry.name, entry.center, entry.geometry]
	var freedom_text := "degré de liberté" if entry.count == 1 else "degrés de liberté"
	$Margin/Layout/Description.text = "%s %s\n%s" % [entry.count, freedom_text, entry.motion]
	var components := ["Tx", "Ty", "Tz", "Rx", "Ry", "Rz"]
	var lines: Array[String] = []
	for axis in range(6):
		var status := "libre" if entry.dof[axis] else "bloquée"
		if selected_joint == Joint.SCREW and axis in [0, 3]:
			status = "liée"
		lines.append(components[axis] + " : " + status)
	$Margin/Layout/DegreesOfFreedom.text = "    ".join(lines.slice(0, 3)) + "\n" + "    ".join(lines.slice(3, 6))
	$Margin/Layout/Views/View2D/Heading.text = "Vue 2D · plan XZ" if selected_joint > Joint.SLIDER else "Vue 2D · plan XY"
	animate_button.disabled = selected_joint == Joint.FIXED
	animate_button.text = "Liaison fixe" if animate_button.disabled else "Animer"
	_apply_motion()
	_update_camera_orbit()
	queue_redraw()


func _is_rz_test() -> bool:
	return selected_joint in [Joint.SPHERICAL, Joint.FINGER] and test_rz.button_pressed


func _on_test_rz_toggled(_enabled: bool) -> void:
	phase = 0.0
	_apply_motion()
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			orbit_dragging = view_3d.get_global_rect().has_point(event.position)
			if orbit_dragging:
				get_viewport().set_input_as_handled()
		else:
			# Le relâchement termine aussi le geste en dehors de la vue 3D.
			if orbit_dragging:
				get_viewport().set_input_as_handled()
			orbit_dragging = false
	elif event is InputEventMouseMotion and orbit_dragging:
		if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			orbit_dragging = false
			return
		orbit_yaw = wrapf(orbit_yaw - event.relative.x * ORBIT_SENSITIVITY, -PI, PI)
		orbit_pitch = wrapf(orbit_pitch - event.relative.y * ORBIT_SENSITIVITY, -PI, PI)
		_update_camera_orbit()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		orbit_dragging = false


func _update_camera_orbit() -> void:
	# Une base orthogonale permet de passer au-dessus et au-dessous sans
	# singularité de look_at, même lorsque la caméra franchit les pôles.
	var orientation := Basis(Vector3.UP, orbit_yaw) * Basis(Vector3.RIGHT, orbit_pitch)
	# Les schémas du PDF utilisent Z vertical. La caméra garde ce repère
	# pour présenter les contacts de normale Z comme des appuis horizontaux.
	if selected_joint > Joint.SLIDER:
		orientation = Basis(Vector3.RIGHT, PI / 2.0) * orientation
	camera_3d.transform = Transform3D(orientation, CAMERA_TARGET + orientation.z * orbit_distance)
	if is_instance_valid(axes_overlay):
		axes_overlay.queue_redraw()


func _process(delta: float) -> void:
	phase = fmod(phase + delta * TAU / PERIOD_SECONDS, TAU * 20.0)
	_apply_motion()
	queue_redraw()


func _apply_motion() -> void:
	var dof: Array = CATALOG[selected_joint].dof
	motion_translation = Vector3(MAX_TRAVEL * sin(phase) * dof[0], 0.4 * sin(phase * 0.7) * dof[1], 0.0)
	motion_rotation = Vector3(0.65 * sin(phase * 0.8) * dof[3], 0.55 * sin(phase * 1.1) * dof[4], 0.6 * sin(phase * 0.9) * dof[5])
	if _is_rz_test():
		# Même sollicitation pour les deux rotules ; Rx et Ry sont au repos.
		var requested := PI / 3.0 * sin(phase)
		motion_rotation = Vector3(0, 0, requested * dof[5])
		$Margin/Layout/Views/View2D/Heading.text = "Vue 2D · dessus (XY) · test Rz"
		$Margin/Layout/Description.text = "Rz %s · repère orange solidaire de la pièce\nAngle demandé : %+.0f°   |   Angle obtenu : %+.0f°" % ["bloquée" if selected_joint == Joint.FINGER else "libre", rad_to_deg(requested), rad_to_deg(motion_rotation.z)]
	elif selected_joint in [Joint.SPHERICAL, Joint.FINGER]:
		$Margin/Layout/Views/View2D/Heading.text = "Vue 2D · plan XZ"
		$Margin/Layout/Description.text = "%s degrés de liberté\n%s" % [CATALOG[selected_joint].count, CATALOG[selected_joint].motion]
	if selected_joint == Joint.SCREW:
		motion_rotation.x = 1.5 * PI * sin(phase)
		motion_translation.x = SCREW_PITCH * motion_rotation.x / TAU
	if selected_joint == Joint.PIVOT:
		motion_rotation.z = -MAX_ANGLE * sin(phase)
	angle = -motion_rotation.z
	travel = motion_translation.x
	mobile_3d.position = motion_translation
	# Pour les contacts, l'origine du solide mobile est son centre géométrique.
	if selected_joint == Joint.POINT:
		mobile_3d.position.z = 0.32
	elif selected_joint == Joint.LINE:
		mobile_3d.position.z = 0.26
	# Rotation extrinsèque : la ligne reste dans XY (Ry = 0), normale Z.
	mobile_3d.basis = Basis(Vector3.BACK, motion_rotation.z) * Basis(Vector3.UP, motion_rotation.y) * Basis(Vector3.RIGHT, motion_rotation.x)


func _draw() -> void:
	if not is_instance_valid(diagram):
		return

	# Le dessin s'adapte à l'espace laissé libre par les éléments d'interface.
	var area := Rect2(diagram.global_position - global_position, diagram.size)
	var unit: float = minf(area.size.x / 760.0, area.size.y / 280.0)
	var origin := area.position + Vector2(area.size.x * 0.43, area.size.y * 0.50)
	if _is_rz_test():
		_draw_rz_test(origin, unit)
	elif selected_joint == Joint.SLIDER:
		_draw_slider_2d(origin, unit)
	elif selected_joint == Joint.PIVOT:
		_draw_pivot_2d(origin, unit)
	else:
		_draw_catalog_2d(origin, unit)
	_draw_2d_axes(area)


func _draw_rz_test(origin: Vector2, unit: float) -> void:
	var radius := 100.0 * unit
	draw_arc(origin, radius, 0, TAU, 64, FIXED_COLOR.lightened(0.5), 2.0, true)
	draw_circle(origin, 32.0 * unit, MOBILE_COLOR)
	# La direction demandée reste visible quand la rotation est bloquée.
	var requested := Vector2.RIGHT.rotated(-PI / 3.0 * sin(phase)) * radius
	draw_dashed_line(origin, origin + requested, FIXED_COLOR, 2.0, 5.0, true)
	var actual := Vector2.RIGHT.rotated(-motion_rotation.z) * radius
	_draw_axis(self, origin, actual, "", POINTER_COLOR)
	draw_circle(origin + actual, 6.0, POINTER_COLOR)
	draw_string(get_theme_default_font(), origin + Vector2(-8, 42), "O", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20, FIXED_COLOR)
	draw_string(get_theme_default_font(), origin + Vector2(-105, -125) * unit,
		"Pointillés : angle demandé", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15, FIXED_COLOR)
	if selected_joint == Joint.FINGER:
		# Petit doigt et butée schématiques, fixes pendant ce test isolé.
		draw_line(origin + Vector2(-30, 0) * unit, origin + Vector2(-65, 0) * unit, POINTER_COLOR, 6.0, true)
		draw_rect(Rect2(origin + Vector2(-72, -14) * unit, Vector2(15, 28) * unit), FIXED_COLOR, false, 2.0)


func _draw_pivot_2d(origin: Vector2, unit: float) -> void:
	var bar_end := origin + Vector2.RIGHT.rotated(angle) * 220.0 * unit
	var base_y: float = origin.y + 62.0 * unit
	var base_left := Vector2(origin.x - 230.0 * unit, base_y)
	var base_right := Vector2(origin.x + 65.0 * unit, base_y)

	# Bâti horizontal hachuré et support fixe du pivot.
	draw_line(base_left, base_right, FIXED_COLOR, 7.0 * unit, true)
	for index in range(12):
		var hatch_start := base_left + Vector2(float(index) * 25.0 * unit, 0.0)
		draw_line(hatch_start, hatch_start + Vector2(-13.0, 18.0) * unit, FIXED_COLOR, 2.0 * unit, true)
	draw_line(Vector2(origin.x, base_y), origin, FIXED_COLOR, 12.0 * unit, true)

	# Solide mobile et symbole circulaire de la liaison pivot.
	draw_line(origin, bar_end, MOBILE_COLOR, 16.0 * unit, true)
	draw_circle(bar_end, 8.0 * unit, MOBILE_COLOR)
	draw_circle(origin, 24.0 * unit, BACKGROUND_COLOR)
	draw_arc(origin, 24.0 * unit, 0.0, TAU, 64, FIXED_COLOR, 4.0 * unit, true)
	draw_circle(origin, 11.0 * unit, MOBILE_COLOR)
	draw_circle(origin, 3.0 * unit, BACKGROUND_COLOR)
	draw_string(get_theme_default_font(), origin + Vector2(-43.0, -31.0) * unit,
		"O", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 24, FIXED_COLOR)


func _draw_slider_2d(origin: Vector2, unit: float) -> void:
	# Le point A reste au centre du guide fixe, la tige coulisse selon X.
	var offset := Vector2(travel * 100.0, 0.0) * unit
	draw_line(origin + Vector2(-190.0, 65.0) * unit,
		origin + Vector2(190.0, 65.0) * unit, FIXED_COLOR, 6.0 * unit, true)
	for index in range(16):
		var start := origin + Vector2(-190.0 + index * 25.0, 65.0) * unit
		draw_line(start, start + Vector2(-12.0, 15.0) * unit, FIXED_COLOR, 2.0 * unit, true)
	draw_line(origin, origin + Vector2(0.0, 65.0) * unit, FIXED_COLOR, 10.0 * unit, true)
	draw_rect(Rect2(origin + offset + Vector2(-190.0, -11.0) * unit,
		Vector2(380.0, 22.0) * unit), MOBILE_COLOR)
	draw_rect(Rect2(origin + Vector2(-42.0, -30.0) * unit,
		Vector2(84.0, 60.0) * unit), FIXED_COLOR, false, 5.0 * unit)
	draw_circle(origin, 3.0 * unit, FIXED_COLOR)
	draw_string(get_theme_default_font(), origin + Vector2(-12.0, -42.0) * unit,
		"A", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 24, FIXED_COLOR)


func _project_xz(point: Vector3, origin: Vector2, unit: float) -> Vector2:
	return origin + Vector2(point.x, -point.z) * 100.0 * unit


func _draw_catalog_2d(origin: Vector2, unit: float) -> void:
	# Schémas pédagogiques en projection XZ. La pose est commune à la 3D.
	var contact := selected_joint in [Joint.PLANE, Joint.LINE, Joint.POINT]
	var base_z := 0.0 if contact else -0.72
	var left := _project_xz(Vector3(-1.8, 0, base_z), origin, unit)
	var right := _project_xz(Vector3(1.8, 0, base_z), origin, unit)
	draw_line(left, right, FIXED_COLOR, 4.0, true)
	for index in range(15):
		var start := left.lerp(right, float(index) / 14.0)
		draw_line(start, start + Vector2(-9, 10) * unit, FIXED_COLOR, 1.5, true)
	if not contact:
		draw_line(origin, _project_xz(Vector3(0, 0, base_z), origin, unit), FIXED_COLOR, 5.0, true)
	var pose := mobile_3d.transform
	match selected_joint:
		Joint.FIXED:
			draw_rect(Rect2(origin + Vector2(-45, -28) * unit, Vector2(90, 56) * unit), FIXED_COLOR)
			draw_line(origin, origin + Vector2(0, -150) * unit, MOBILE_COLOR, 8.0, true)
		Joint.PIVOT_X, Joint.CYLINDRICAL, Joint.SCREW:
			var start := _project_xz(pose * Vector3(-1.7, 0, 0), origin, unit)
			var end := _project_xz(pose * Vector3(1.7, 0, 0), origin, unit)
			draw_line(start, end, MOBILE_COLOR, 12.0 * unit, true)
			draw_rect(Rect2(origin + Vector2(-48, -28) * unit, Vector2(96, 56) * unit), FIXED_COLOR, false, 3.0)
			if selected_joint == Joint.PIVOT_X:
				for side in [-1.0, 1.0]:
					var edge := origin + Vector2(side * 58, 0) * unit
					draw_line(edge + Vector2(0, -22) * unit, edge + Vector2(0, 22) * unit, MOBILE_COLOR, 3.0, true)
			if selected_joint == Joint.SCREW:
				var points := PackedVector2Array()
				for step in range(81):
					var x := -1.7 + float(step) * 3.4 / 80.0
					points.append(_project_xz(pose * Vector3(x, 0.19 * cos(TAU * x / SCREW_PITCH), 0.19 * sin(TAU * x / SCREW_PITCH)), origin, unit))
				draw_polyline(points, MOBILE_COLOR.lightened(0.3), 2.0, true)
			var handle := _project_xz(pose * Vector3(1.25, 0, 0), origin, unit)
			draw_line(handle, _project_xz(pose * Vector3(1.25, 0, 0.85), origin, unit), MOBILE_COLOR, 5.0, true)
		Joint.SPHERICAL, Joint.ANNULAR, Joint.FINGER, Joint.POINT:
			var center := _project_xz(pose.origin, origin, unit)
			if selected_joint == Joint.ANNULAR:
				draw_rect(Rect2(origin + Vector2(-105, -38) * unit, Vector2(210, 76) * unit), FIXED_COLOR, false, 3.0)
			elif selected_joint != Joint.POINT:
				draw_arc(origin, 40.0 * unit, 0.15, PI * 1.9, 48, FIXED_COLOR, 4.0, true)
			draw_circle(center, 32.0 * unit, BACKGROUND_COLOR)
			draw_arc(center, 32.0 * unit, 0, TAU, 48, MOBILE_COLOR, 3.0, true)
			draw_line(center, _project_xz(pose * Vector3(0, 0, 1.15), origin, unit), MOBILE_COLOR, 5.0, true)
			if selected_joint == Joint.FINGER:
				draw_line(center, _project_xz(pose * Vector3(-0.5, 0, 0), origin, unit), MOBILE_COLOR, 5.0, true)
		Joint.PLANE:
			var points := PackedVector2Array()
			for point in [Vector3(-0.65, 0, 0.03), Vector3(0.65, 0, 0.03), Vector3(0.65, 0, 0.22), Vector3(-0.65, 0, 0.22)]:
				points.append(_project_xz(pose * point, origin, unit))
			draw_colored_polygon(points, MOBILE_COLOR)
			draw_line(_project_xz(pose.origin, origin, unit), _project_xz(pose * Vector3(0, 0, 0.9), origin, unit), MOBILE_COLOR, 5.0, true)
		Joint.LINE:
			var start := _project_xz(pose * Vector3(-0.8, 0, 0), origin, unit)
			var end := _project_xz(pose * Vector3(0.8, 0, 0), origin, unit)
			draw_line(start, end, MOBILE_COLOR, 52.0 * unit, true)
			draw_line(_project_xz(pose.origin, origin, unit), _project_xz(pose * Vector3(0, 0, 1.0), origin, unit), MOBILE_COLOR, 5.0, true)
	draw_circle(origin, 2.5, FIXED_COLOR)
	draw_string(get_theme_default_font(), origin + Vector2(-10, 25), CATALOG[selected_joint].center,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 21, FIXED_COLOR)


func _draw_2d_axes(area: Rect2) -> void:
	# Repère fixe : X vers la droite, Y vers le haut, Z vers l'observateur.
	var axes_origin := area.position + Vector2(area.size.x - 85.0, area.size.y - 55.0)
	_draw_axis(self, axes_origin, Vector2(45.0, 0.0), "X", AXIS_COLORS[0])
	var side_view := selected_joint > Joint.SLIDER and not _is_rz_test()
	var vertical_axis := 2 if side_view else 1
	var normal_axis := 1 if side_view else 2
	_draw_axis(self, axes_origin, Vector2(0.0, -45.0), "Z" if side_view else "Y", AXIS_COLORS[vertical_axis])
	draw_arc(axes_origin, 6.0, 0.0, TAU, 32, AXIS_COLORS[normal_axis], 2.0, true)
	if side_view:
		draw_line(axes_origin - Vector2(3, 3), axes_origin + Vector2(3, 3), AXIS_COLORS[1], 2.0, true)
		draw_line(axes_origin + Vector2(-3, 3), axes_origin + Vector2(3, -3), AXIS_COLORS[1], 2.0, true)
	else:
		draw_circle(axes_origin, 2.0, AXIS_COLORS[2])
	draw_string(get_theme_default_font(), axes_origin + Vector2(-18.0, 24.0),
		"Y (entrant)" if side_view else "Z (sortant)", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15, AXIS_COLORS[normal_axis])


func _draw_3d_axes() -> void:
	var axes_origin := Vector2(65.0, axes_overlay.size.y - 55.0)
	var directions := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var labels := ["X", "Y", "Z"]
	for index in range(3):
		# Projection des axes du bâti dans la base de la caméra orbitale.
		var direction: Vector3 = camera_3d.basis.inverse() * directions[index]
		var projected := Vector2(direction.x, -direction.y) * 45.0
		_draw_axis(axes_overlay, axes_origin, projected, labels[index], AXIS_COLORS[index])


func _draw_axis(canvas: Control, origin: Vector2, direction: Vector2, label: String, color: Color) -> void:
	var tip := origin + direction
	if direction.length() > 8.0:
		canvas.draw_line(origin, tip, color, 2.0, true)
		var forward := direction.normalized()
		var side := forward.orthogonal()
		canvas.draw_colored_polygon(PackedVector2Array([
			tip, tip - forward * 8.0 + side * 4.0, tip - forward * 8.0 - side * 4.0
		]), color)
	else:
		canvas.draw_circle(tip, 3.0, color)
	canvas.draw_string(get_theme_default_font(), tip + Vector2(7.0, -5.0),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, color)


func _build_3d_view() -> void:
	# Toutes les formes sont des primitives Godot, sans ressource externe.
	var world := Node3D.new()
	viewport_3d.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.65
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, -30.0, 0.0)
	light.light_energy = 1.0
	world.add_child(light)
	camera_3d = Camera3D.new()
	camera_3d.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera_3d.size = 5.8
	world.add_child(camera_3d)
	var initial_offset := Vector3(4.0, 2.8, 7.0) - CAMERA_TARGET
	orbit_distance = initial_offset.length()
	orbit_yaw = atan2(initial_offset.x, initial_offset.z)
	orbit_pitch = -atan2(initial_offset.y, Vector2(initial_offset.x, initial_offset.z).length())
	_update_camera_orbit()
	camera_3d.current = true
	model_3d = Node3D.new()
	world.add_child(model_3d)
	_build_pivot_model(model_3d)


func _build_pivot_model(world: Node3D) -> void:
	# Bâti horizontal, montant arrière et axe fixe suivant Z.
	_add_box(world, Vector3(3.1, 0.18, 1.15), Vector3(-0.8, -0.8, -0.25), FIXED_COLOR)
	_add_box(world, Vector3(0.42, 0.8, 0.36), Vector3(0.0, -0.35, -0.4), FIXED_COLOR)
	_add_axle(world, 0.22, 1.05, Vector3(0.0, 0.0, -0.05), FIXED_COLOR)

	# L'origine de ce nœud est exactement au centre O de la liaison.
	mobile_3d = Node3D.new()
	world.add_child(mobile_3d)
	_add_box(mobile_3d, Vector3(2.2, 0.18, 0.18), Vector3(1.1, 0.0, 0.22), MOBILE_COLOR)
	_add_axle(mobile_3d, 0.30, 0.24, Vector3(0.0, 0.0, 0.22), MOBILE_COLOR)
	_add_axle(world, 0.12, 0.08, Vector3(0.0, 0.0, 0.52), Color(0.75, 0.8, 0.86))
	var origin_label := Label3D.new()
	origin_label.text = "O"
	origin_label.font_size = 48
	origin_label.pixel_size = 0.006
	origin_label.modulate = FIXED_COLOR
	origin_label.outline_size = 0
	origin_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	origin_label.position = Vector3(-0.38, 0.42, 0.3)
	world.add_child(origin_label)


func _build_slider_model(world: Node3D) -> void:
	_add_box(world, Vector3(3.8, 0.18, 1.15), Vector3(0.0, -0.8, 0.0), FIXED_COLOR)
	_add_box(world, Vector3(0.65, 0.45, 0.55), Vector3(0.0, -0.5, 0.0), FIXED_COLOR)
	# Guide rectangulaire creux : sa section empêche les rotations de la tige.
	for side in [-1.0, 1.0]:
		_add_box(world, Vector3(0.84, 0.14, 0.64), Vector3(0.0, side * 0.25, 0.0), FIXED_COLOR)
		_add_box(world, Vector3(0.84, 0.36, 0.14), Vector3(0.0, 0.0, side * 0.25), FIXED_COLOR)
	mobile_3d = Node3D.new()
	world.add_child(mobile_3d)
	_add_box(mobile_3d, Vector3(3.8, 0.32, 0.32), Vector3.ZERO, MOBILE_COLOR)
	var center_label := Label3D.new()
	center_label.text = "A"
	center_label.font_size = 48
	center_label.pixel_size = 0.006
	center_label.modulate = FIXED_COLOR
	center_label.outline_size = 0
	center_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	center_label.position = Vector3(0.0, 0.52, 0.0)
	world.add_child(center_label)


func _build_catalog_model(world: Node3D) -> void:
	var contact := selected_joint in [Joint.PLANE, Joint.LINE, Joint.POINT]
	if contact:
		# Le dessus du plan fixe est z = 0.
		_add_box(world, Vector3(3.8, 2.5, 0.16), Vector3(0, 0, -0.08), FIXED_COLOR)
	else:
		_add_box(world, Vector3(3.3, 1.2, 0.16), Vector3(0, 0, -0.8), FIXED_COLOR)
		_add_box(world, Vector3(0.5, 0.5, 0.6), Vector3(0, 0, -0.45), FIXED_COLOR)
	mobile_3d = Node3D.new()
	world.add_child(mobile_3d)
	match selected_joint:
		Joint.FIXED:
			_add_box(world, Vector3(0.85, 0.75, 0.6), Vector3.ZERO, FIXED_COLOR)
			_add_box(mobile_3d, Vector3(0.25, 0.25, 1.6), Vector3(0, 0, 0.7), MOBILE_COLOR)
		Joint.PIVOT_X, Joint.CYLINDRICAL, Joint.SCREW:
			for x in [-0.4, 0.4]:
				_add_ring(world, Vector3(x, 0, 0), 0.20, 0.34, Vector3(0, 0, PI / 2), FIXED_COLOR)
			_add_cylinder_x(mobile_3d, 0.17, 3.4, Vector3.ZERO, MOBILE_COLOR)
			_add_box(mobile_3d, Vector3(0.13, 0.13, 0.85), Vector3(1.25, 0, 0.4), MOBILE_COLOR)
			if selected_joint == Joint.PIVOT_X:
				for x in [-0.58, 0.58]:
					_add_cylinder_x(mobile_3d, 0.29, 0.12, Vector3(x, 0, 0), MOBILE_COLOR)
			if selected_joint == Joint.SCREW:
				_add_thread(mobile_3d)
		Joint.SPHERICAL, Joint.FINGER:
			_add_sphere(mobile_3d, 0.32)
			_add_box(mobile_3d, Vector3(0.14, 0.14, 1.0), Vector3(0, 0, 0.65), MOBILE_COLOR)
			_add_ring(world, Vector3.ZERO, 0.35, 0.43, Vector3.ZERO, FIXED_COLOR)
			_add_ring(world, Vector3.ZERO, 0.35, 0.43, Vector3(0, 0, PI / 2), FIXED_COLOR)
			if selected_joint == Joint.FINGER:
				_add_box(mobile_3d, Vector3(0.55, 0.08, 0.08), Vector3(-0.25, 0, 0), Color(0.9, 0.55, 0.1))
			# Un repère asymétrique rend visible la rotation autour de la tige Z.
			_add_box(mobile_3d, Vector3(1.0, 0.10, 0.10), Vector3(0.5, 0, 0.95), POINTER_COLOR)
			_add_box(mobile_3d, Vector3(0.20, 0.20, 0.20), Vector3(1.0, 0, 0.95), POINTER_COLOR)
		Joint.ANNULAR:
			for x in [-1.0, 1.0]:
				_add_ring(world, Vector3(x, 0, 0), 0.32, 0.42, Vector3(0, 0, PI / 2), FIXED_COLOR)
			for y in [-0.36, 0.36]:
				_add_box(world, Vector3(2.0, 0.08, 0.08), Vector3(0, y, 0), FIXED_COLOR)
			_add_sphere(mobile_3d, 0.32)
			_add_box(mobile_3d, Vector3(0.13, 0.13, 1.0), Vector3(0, 0, 0.65), MOBILE_COLOR)
		Joint.PLANE:
			_add_box(mobile_3d, Vector3(1.3, 0.95, 0.2), Vector3(0, 0, 0.1), MOBILE_COLOR)
			_add_box(mobile_3d, Vector3(0.12, 0.12, 0.8), Vector3(0, 0, 0.5), MOBILE_COLOR)
		Joint.LINE:
			_add_cylinder_x(mobile_3d, 0.26, 1.6, Vector3.ZERO, MOBILE_COLOR)
			_add_box(mobile_3d, Vector3(0.12, 0.12, 0.8), Vector3(0, 0, 0.5), MOBILE_COLOR)
		Joint.POINT:
			_add_sphere(mobile_3d, 0.32)
			_add_box(mobile_3d, Vector3(0.12, 0.12, 1.0), Vector3(0, 0, 0.65), MOBILE_COLOR)
	var label := Label3D.new()
	label.text = CATALOG[selected_joint].center
	label.font_size = 48
	label.pixel_size = 0.006
	label.modulate = FIXED_COLOR
	label.outline_size = 3
	label.outline_modulate = BACKGROUND_COLOR
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(-0.5, -0.25, 0.55)
	world.add_child(label)


func _add_sphere(parent: Node3D, radius: float) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	_add_mesh(parent, mesh, Vector3.ZERO, MOBILE_COLOR)


func _add_cylinder_x(parent: Node3D, radius: float, length: float, center: Vector3, color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 24
	_add_mesh(parent, mesh, center, color).rotation.z = PI / 2.0


func _add_ring(parent: Node3D, center: Vector3, inner: float, outer: float, rotation_angles: Vector3, color: Color) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 32
	mesh.ring_segments = 12
	_add_mesh(parent, mesh, center, color).rotation = rotation_angles


func _add_thread(parent: Node3D) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for step in range(257):
		var x := -1.7 + float(step) * 3.4 / 256.0
		mesh.surface_add_vertex(Vector3(x, 0.185 * cos(TAU * x / SCREW_PITCH), 0.185 * sin(TAU * x / SCREW_PITCH)))
	mesh.surface_end()
	_add_mesh(parent, mesh, Vector3.ZERO, Color(0.95, 0.75, 0.2))


func _add_box(parent: Node3D, dimensions: Vector3, center: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	_add_mesh(parent, mesh, center, color)


func _add_axle(parent: Node3D, radius: float, length: float, center: Vector3, color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 32
	var instance := _add_mesh(parent, mesh, center, color)
	instance.rotation.x = PI / 2.0


func _add_mesh(parent: Node3D, mesh: Mesh, center: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.75
	instance.mesh = mesh
	instance.material_override = material
	instance.position = center
	parent.add_child(instance)
	return instance
