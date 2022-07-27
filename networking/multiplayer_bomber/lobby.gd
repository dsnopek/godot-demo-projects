extends Control

const NAKAMA_HOST := '127.0.0.1'
const NAKAMA_PORT := 7350
const NAKAMA_SCHEME := "http"
const NAKAMA_KEY := 'defaultkey'
const NAKAMA_TIMEOUT := 3
const NAKAMA_LOG_LEVEL := NakamaLogger.LOG_LEVEL.ERROR

onready var login_screen = $LoginScreen
onready var join_screen = $JoinScreen
onready var players_screen = $PlayersScreen
onready var error_dialog = $ErrorDialog

onready var email_field = $LoginScreen/MarginContainer/VBoxContainer/GridContainer/EmailField
onready var username_field = $LoginScreen/MarginContainer/VBoxContainer/GridContainer/UsernameField
onready var password_field = $LoginScreen/MarginContainer/VBoxContainer/GridContainer/PasswordField
onready var create_account_checkbox = $LoginScreen/MarginContainer/VBoxContainer/GridContainer/CreateAccountCheckbox
onready var login_error_label = $LoginScreen/MarginContainer/VBoxContainer/ErrorLabel

onready var join_match_field = $JoinScreen/MarginContainer/VBoxContainer/JoinMatchContainer/JoinMatchField
onready var join_named_match_field = $JoinScreen/MarginContainer/VBoxContainer/JoinNamedMatchContainer/JoinNamedMatchField
onready var join_error_label = $JoinScreen/MarginContainer/VBoxContainer/ErrorLabel

onready var match_id_field = $PlayersScreen/MarginContainer/VBoxContainer/HBoxContainer/MatchIdField
onready var players_list = $PlayersScreen/MarginContainer/VBoxContainer/List
onready var game_start_button = $PlayersScreen/MarginContainer/VBoxContainer/Start

var nakama_client: NakamaClient
var nakama_session: NakamaSession
var nakama_socket: NakamaSocket

var nakama_multiplayer_bridge: NakamaMultiplayerBridge

func _ready():
	# Called every time the node is added to the scene.
	gamestate.connect("connection_failed", self, "_on_connection_failed")
	gamestate.connect("connection_succeeded", self, "_on_connection_success")
	gamestate.connect("player_list_changed", self, "refresh_lobby")
	gamestate.connect("game_ended", self, "_on_game_ended")
	gamestate.connect("game_error", self, "_on_game_error")

	nakama_client = Nakama.create_client(NAKAMA_KEY, NAKAMA_HOST, NAKAMA_PORT, NAKAMA_SCHEME, NAKAMA_TIMEOUT, NAKAMA_LOG_LEVEL)

func _on_LoginButton_pressed() -> void:
	var create_account = create_account_checkbox.pressed
	var email = email_field.text
	var username = username_field.text if create_account else null
	var password = password_field.text

	if create_account:
		if email == '' or username == '' or password == '':
			login_error_label.text = "Email, username and password are required to create an account!"
			return
	elif email == '' or password == '':
		login_error_label.text = "Email and password are required!"
		return

	login_error_label.text = 'Logging in...'

	nakama_session = yield(nakama_client.authenticate_email_async(email, password, username, create_account), "completed")
	if nakama_session.is_exception():
		login_error_label.text = "Unable to login: %s" % nakama_session
		return

	gamestate.player_name = nakama_session.username

	nakama_socket = Nakama.create_socket_from(nakama_client)
	var res = yield(nakama_socket.connect_async(nakama_session), "completed")
	if res.is_exception():
		login_error_label.text = "Unable to open socket: %s" % res
		return

	nakama_multiplayer_bridge = NakamaMultiplayerBridge.new(nakama_socket)
	nakama_multiplayer_bridge.connect("match_error", self, "_on_nakama_multiplayer_bridge_match_error")
	get_tree().set_network_peer(nakama_multiplayer_bridge.multiplayer_peer)

	login_screen.visible = false
	join_screen.visible = true

func _on_CreateAccountCheckbox_toggled(checked: bool) -> void:
	get_tree().set_group("username_field", "visible", checked)

func _on_CreateMatchButton_pressed() -> void:
	get_tree().set_group("join_button", "disabled", true)
	join_error_label.text = "Creating match..."
	nakama_multiplayer_bridge.create_match()

func _on_JoinMatchButton_pressed() -> void:
	var match_id = join_match_field.text
	if match_id == '':
		join_error_label.text = "Must enter a match ID"
		return

	get_tree().set_group("join_button", "disabled", true)
	join_error_label.text = "Joining match..."
	nakama_multiplayer_bridge.join_match(match_id)

func _on_JoinNamedMatchButton_pressed() -> void:
	var match_name = join_named_match_field.text
	if match_name == '':
		join_error_label.text = "Must enter a match name"
		return

	get_tree().set_group("join_button", "disabled", true)
	join_error_label.text = "Joining match..."
	nakama_multiplayer_bridge.join_named_match(match_name)

func _on_FindMatchButton_pressed() -> void:
	get_tree().set_group("join_button", "disabled", true)
	join_error_label.text = "Looking for other players..."
	nakama_multiplayer_bridge.start_matchmaking()

func _on_nakama_multiplayer_bridge_match_error(msg: String) -> void:
	get_tree().set_group("join_button", "disabled", false)
	join_error_label.text = "ERROR: " + msg

func _on_connection_success():
	join_screen.visible = false
	players_screen.visible = true
	match_id_field.text = nakama_multiplayer_bridge.match_id

func _on_connection_failed():
	# This is handled by _on_nakama_multiplayer_bridge_match_error().
	pass

func _on_game_ended():
	reset_ui()

func _on_game_error(errtxt):
	error_dialog.dialog_text = errtxt
	error_dialog.popup_centered_minsize()
	reset_ui()

func reset_ui():
	show()
	email_field.text = ''
	username_field.text = ''
	password_field.text = ''
	create_account_checkbox.pressed = false

	join_match_field.text = ''
	join_named_match_field.text = ''
	get_tree().set_group("join_button", "disabled", false)

	login_screen.visible = false
	join_screen.visible = true
	players_screen.visible = false

func refresh_lobby():
	var players = gamestate.get_player_list()
	players.sort()
	players_list.clear()
	players_list.add_item(gamestate.get_player_name() + " (You)")
	for p in players:
		players_list.add_item(p)

	game_start_button.disabled = not get_tree().is_network_server()

func _on_start_pressed():
	gamestate.begin_game()
