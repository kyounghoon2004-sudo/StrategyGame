extends CanvasLayer
class_name TacticalSidebar

## 시안 1 좌측 25% 전술 사이드바.
## CanvasLayer 루트로 카메라와 무관하게 고정하고, 내부 Control에 320x720 UI를 만든다.

signal command_entered(command: String)
signal button_pressed(button_id: StringName)

const SIDEBAR_SIZE: Vector2 = Vector2(320, 720)
const PANEL_COLOR: Color = Color(0.070588, 0.070588, 0.094118, 1.0) # #121218
const GOLD: Color = Color(0.831373, 0.686275, 0.215686, 1.0) # #D4AF37
const GOLD_DARK: Color = Color(0.65098, 0.486275, 0.117647, 1.0) # #A67C1E
const CREAM: Color = Color(0.972549, 0.976471, 0.980392, 1.0) # #F8F9FA

var _content: Control
var _dialogue_label: Label
var _command_input: LineEdit
var _portrait: TextureRect
var _buttons: Dictionary = {}


func _ready() -> void:
	layer = 100
	_build_layout()
	_focus_input()


func _style(background: Color, border: Color, border_width: int = 1, radius: int = 0) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


func _make_label(text_value: String, position: Vector2, size: Vector2, font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.position = position
	label.size = size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


func _build_layout() -> void:
	_content = Control.new()
	_content.name = "SidebarContent"
	_content.position = Vector2.ZERO
	_content.size = SIDEBAR_SIZE
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)

	var panel: Panel = Panel.new()
	panel.name = "SidebarPanel"
	panel.position = Vector2(0, 0)
	panel.size = SIDEBAR_SIZE
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style(PANEL_COLOR, GOLD, 2, 0))
	_content.add_child(panel)

	var inner: Panel = Panel.new()
	inner.name = "FiligreeInnerBorder"
	inner.position = Vector2(6, 6)
	inner.size = Vector2(308, 708)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_stylebox_override("panel", _style(Color(0, 0, 0, 0), GOLD_DARK, 1, 0))
	_content.add_child(inner)

	_content.add_child(_make_label("전술 지휘 · 서유선", Vector2(122, 18), Vector2(180, 24), 13, GOLD))
	_content.add_child(_make_label("집중 전술형 전장", Vector2(122, 42), Vector2(180, 18), 9, Color(0.67, 0.62, 0.48, 1)))

	_portrait = TextureRect.new()
	_portrait.name = "AdvisorPortrait"
	_portrait.position = Vector2(18, 18)
	_portrait.size = Vector2(88, 88)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_portrait.texture = load("res://assets/ui/portrait_advisor.png") as Texture2D
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_portrait)

	var portrait_frame: Panel = Panel.new()
	portrait_frame.name = "PortraitFrame"
	portrait_frame.position = Vector2(14, 14)
	portrait_frame.size = Vector2(96, 96)
	portrait_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_frame.add_theme_stylebox_override("panel", _style(Color(0, 0, 0, 0), GOLD_DARK, 2, 0))
	_content.add_child(portrait_frame)
	_content.move_child(portrait_frame, 2)

	var bubble: Panel = Panel.new()
	bubble.name = "DialogueBubble"
	bubble.position = Vector2(18, 126)
	bubble.size = Vector2(284, 104)
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bubble.add_theme_stylebox_override("panel", _style(CREAM, GOLD_DARK, 1, 2))
	_content.add_child(bubble)

	var tail: Polygon2D = Polygon2D.new()
	tail.name = "DialogueTail"
	tail.position = Vector2(30, 218)
	tail.polygon = PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(6, 16)])
	tail.color = CREAM
	tail.z_index = 2
	_content.add_child(tail)

	_dialogue_label = _make_label("주공, 전황을 아뢰옵니다.\n적의 보급로가 노출되어 있사오니,\n지금 결단의 시점이옵니다.", Vector2(32, 138), Vector2(256, 84), 11, Color(0.09, 0.08, 0.07, 1))
	_dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(_dialogue_label)

	_content.add_child(_make_label("전술 추천", Vector2(20, 250), Vector2(280, 20), 10, GOLD))
	_add_tactical_button("advance", "전진", "res://assets/ui/ui_icon_sword.png", 278)
	_add_tactical_button("defense", "방어", "res://assets/ui/ui_icon_shield.png", 326)
	_add_tactical_button("scout", "정찰", "res://assets/ui/ui_icon_forest.png", 374)

	var separator: ColorRect = ColorRect.new()
	separator.position = Vector2(18, 430)
	separator.size = Vector2(284, 1)
	separator.color = Color(GOLD_DARK, 0.55)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(separator)

	_content.add_child(_make_label("평야/도로: 넓은 시야  ·  숲/산지: 2~3타일", Vector2(20, 446), Vector2(280, 18), 9, Color(0.62, 0.58, 0.47, 1)))
	_content.add_child(_make_label("초록 안전 · 주황 피로 · 빨강 급행 · 검정 탈진", Vector2(20, 468), Vector2(280, 18), 9, Color(0.62, 0.58, 0.47, 1)))

	var command_panel: Panel = Panel.new()
	command_panel.name = "CommandInputPanel"
	command_panel.position = Vector2(16, 674)
	command_panel.size = Vector2(288, 32)
	command_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	command_panel.add_theme_stylebox_override("panel", _style(Color(0.05098, 0.05098, 0.070588, 1), GOLD_DARK, 1, 1))
	_content.add_child(command_panel)

	var prompt: Label = _make_label(">", Vector2(8, 4), Vector2(16, 24), 13, GOLD)
	command_panel.add_child(prompt)
	_command_input = LineEdit.new()
	_command_input.name = "CommandInput"
	_command_input.position = Vector2(24, 3)
	_command_input.size = Vector2(254, 26)
	_command_input.placeholder_text = "명령을 입력하세요..."
	_command_input.add_theme_font_size_override("font_size", 11)
	_command_input.add_theme_color_override("font_color", Color(0.94, 0.94, 0.92, 1))
	_command_input.add_theme_color_override("font_placeholder_color", Color(0.55, 0.55, 0.53, 0.9))
	_command_input.add_theme_color_override("caret_color", Color(1, 0.96, 0.72, 1))
	_command_input.text_submitted.connect(_on_command_submitted)
	command_panel.add_child(_command_input)

	_content.add_child(_make_label("Enter 실행 · 버튼 클릭 · ESC 선택 해제", Vector2(20, 710), Vector2(280, 16), 8, Color(0.46, 0.43, 0.36, 0.8)))


func _add_tactical_button(button_id: String, label_text: String, icon_path: String, y_position: float) -> void:
	var button: Button = Button.new()
	button.name = "Btn_%s" % button_id
	button.position = Vector2(20, y_position)
	button.size = Vector2(282, 38)
	button.text = "   " + label_text
	button.icon = load(icon_path) as Texture2D
	button.alignment = 0
	button.tooltip_text = "전술 추천: %s" % label_text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", Color(0.95, 0.88, 0.65, 1))
	button.add_theme_color_override("font_hover_color", Color(1, 1, 0.9, 1))
	button.add_theme_stylebox_override("normal", _style(Color(0.105, 0.095, 0.08, 1), GOLD_DARK, 1, 1))
	button.add_theme_stylebox_override("hover", _style(Color(0.19, 0.16, 0.09, 1), GOLD, 1, 1))
	button.add_theme_stylebox_override("pressed", _style(Color(0.28, 0.22, 0.08, 1), GOLD, 2, 1))
	button.pressed.connect(_on_tactical_button_pressed.bind(StringName(button_id)))
	_content.add_child(button)
	_buttons[button_id] = button


func _on_tactical_button_pressed(button_id: StringName) -> void:
	button_pressed.emit(button_id)


func _on_command_submitted(text: String) -> void:
	var command: String = text.strip_edges()
	if not command.is_empty():
		command_entered.emit(command)
	_command_input.clear()
	_focus_input()


func set_dialogue(text: String) -> void:
	if _dialogue_label and is_instance_valid(_dialogue_label):
		_dialogue_label.text = text


func set_briefing(text: String, _options: Array = []) -> void:
	set_dialogue(text)


func set_portrait(texture: Texture2D) -> void:
	if _portrait and is_instance_valid(_portrait):
		_portrait.texture = texture


func clear_dialogue() -> void:
	set_dialogue("")


func focus_command() -> void:
	_focus_input()


func focus_input() -> void:
	_focus_input()


func _focus_input() -> void:
	if _command_input and is_instance_valid(_command_input):
		_command_input.grab_focus()


func disable_command_input() -> void:
	if _command_input:
		_command_input.editable = false


func enable_command_input() -> void:
	if _command_input:
		_command_input.editable = true
		_focus_input()
