extends Reference
class_name NakamaMultiplayerBridge

enum MatchState {
	NONE,
	JOINING,
	CONNECTED,
	DISCONNECTED,
}

enum MetaMessageType {
	CLAIM_HOST,
	ASSIGN_PEER_ID,
}

# Read-only variables.
var nakama_socket: NakamaSocket setget _set_readonly
var match_state: int = MatchState.NONE setget _set_readonly
var match_id := '' setget _set_readonly
var multiplayer_peer: NetworkedMultiplayerCustom = NetworkedMultiplayerCustom.new() setget _set_readonly

# Configuration that can be set by the developer.
var meta_op_code: int = 9001
var rpc_op_code: int = 9002

# Internal variables.
var _my_session_id: String
var _my_peer_id: int = 0
var _id_map := {}
var _users := {}
var _matchmaker_ticket := ''

class User extends Reference:
	var presence: NakamaRTAPI.UserPresence
	var peer_id: int = 0

	func _init(p_presence: NakamaRTAPI.UserPresence) -> void:
		presence = p_presence

signal match_error (message)
signal match_joined ()

func _set_readonly(_value) -> void:
	pass

func _init(_nakama_socket: NakamaSocket) -> void:
	nakama_socket = _nakama_socket
	nakama_socket.connect("received_match_presence", self, "_on_nakama_socket_received_match_presence")
	nakama_socket.connect("received_matchmaker_matched", self, "_on_nakama_socket_received_matchmaker_matched")
	nakama_socket.connect("received_match_state", self, "_on_nakama_socket_received_match_state")

	multiplayer_peer.connect("packet_generated", self, "_on_multiplayer_peer_packet_generated")
	multiplayer_peer.set_connection_status(NetworkedMultiplayerPeer.CONNECTION_CONNECTING)

func create_match() -> void:
	if match_state != MatchState.NONE:
		push_error("Cannot create match when state is %s" % MatchState.keys()[match_state])
		return

	match_state = MatchState.JOINING

	var res: NakamaRTAPI.Match = yield(nakama_socket.create_match_async(), "completed")
	if res.is_exception():
		emit_signal("match_error", "Unable to create match")
		leave()
		return

	_setup_match(res)
	_setup_host()

func join_match(_match_id: String) -> void:
	if match_state != MatchState.NONE:
		push_error("Cannot join match when state is %s" % MatchState.keys()[match_state])
		return

	match_state = MatchState.JOINING

	var res: NakamaRTAPI.Match = yield(nakama_socket.join_match_async(_match_id), "completed")
	if res.is_exception():
		emit_signal("match_error", "Unable to join match")
		leave()
		return

	_setup_match(res)

func join_named_match(_match_name: String) -> void:
	if match_state != MatchState.NONE:
		push_error("Cannot join match when state is %s" % MatchState.keys()[match_state])
		return

	match_state = MatchState.JOINING

	var res: NakamaRTAPI.Match = yield(nakama_socket.create_match_async(_match_name), "completed")
	if res.is_exception():
		emit_signal("match_error", "Unable to join match")
		leave()
		return

	_setup_match(res)
	if res.size == 0 or (res.size == 1 and res.presences.size() == 0):
		_setup_host()

func start_matchmaking(p_query : String = "*", p_min_count : int = 2, p_max_count : int = 8, p_string_props : Dictionary = {}, p_numeric_props : Dictionary = {}, p_count_multiple : int = 0) -> void:
	if match_state != MatchState.NONE:
		push_error("Cannot start matchmaking when state is %s" % MatchState.keys()[match_state])
		return

	match_state = MatchState.JOINING

	var res: NakamaRTAPI.MatchmakerTicket = yield(nakama_socket.add_matchmaker_async(p_query, p_min_count, p_max_count, p_string_props, p_numeric_props, p_count_multiple), "completed")
	if res.is_exception():
		emit_signal("match_error", "Unable to start matchmaking")
		leave()
		return

	_matchmaker_ticket = res.ticket

func _on_nakama_socket_received_matchmaker_matched(matchmaker_matched: NakamaRTAPI.MatchmakerMatched) -> void:
	if _matchmaker_ticket != matchmaker_matched.ticket:
		return

	# Get a list of sorted session ids.
	var session_ids := []
	for matchmaker_user in matchmaker_matched.users:
		session_ids.append(matchmaker_user.presence.session_id)
	session_ids.sort()

	var res: NakamaRTAPI.Match = yield(nakama_socket.join_matched_async(matchmaker_matched), "completed")
	if res.is_exception():
		emit_signal("match_error", "Unable to join match")
		leave()
		return

	_setup_match(res)

	# If our session is the first alphabetically, then we'll be the host.
	if _my_session_id == session_ids[0]:
		_setup_host()

		# Add all of the existing peers.
		for presence in res.presences:
			if presence.session_id != _my_session_id:
				_host_add_peer(presence)

func leave() -> void:
	if match_state == MatchState.DISCONNECTED:
		return
	match_state = MatchState.DISCONNECTED

	if match_id:
		yield(nakama_socket.leave_match_async(match_id), "completed")
		match_id = ''
	if _matchmaker_ticket:
		yield(nakama_socket.remove_matchmaker_async(_matchmaker_ticket), "completed")
		_matchmaker_ticket = ''

	multiplayer_peer.set_connection_status(NetworkedMultiplayerPeer.CONNECTION_DISCONNECTED)

func _setup_match(res: NakamaRTAPI.Match) -> void:
	match_id = res.match_id
	_my_session_id = res.self_user.session_id

	_users[_my_session_id] = User.new(res.self_user)

	for presence in res.presences:
		if not _users.has(presence.session_id):
			_users[presence.session_id] = User.new(presence)

func _setup_host() -> void:
	# Claim id 1 and start the match.
	_my_peer_id = 1
	_map_id_to_session(1, _my_session_id)
	match_state = MatchState.CONNECTED
	multiplayer_peer.initialize(_my_peer_id)
	emit_signal("match_joined")

func _generate_id(session_id: String) -> int:
	# Peer ids can only be positive 32-bit signed integers.
	var peer_id: int = session_id.hash() & 0x7FFFFFFF

	# If this peer id is already taken, try to find another.
	while _id_map.has(peer_id):
		peer_id += 1
		if peer_id > 0x7FFFFFFF or peer_id <= 0:
			peer_id = randi() & 0x7FFFFFFF

	return peer_id

func _map_id_to_session(peer_id: int, session_id: String) -> void:
	_id_map[peer_id] = session_id
	_users[session_id].peer_id = peer_id

func _host_add_peer(presence: NakamaRTAPI.UserPresence) -> void:
	var peer_id = _generate_id(presence.session_id)
	_map_id_to_session(peer_id, presence.session_id)
	multiplayer_peer.emit_signal("peer_connected", peer_id)

	# Tell them we are the host.
	nakama_socket.send_match_state_async(match_id, meta_op_code, JSON.print({
		type = MetaMessageType.CLAIM_HOST,
	}), [presence])

	# Assign them a peer_id (tell everyone about it).
	nakama_socket.send_match_state_async(match_id, meta_op_code, JSON.print({
		type = MetaMessageType.ASSIGN_PEER_ID,
		session_id = presence.session_id,
		peer_id = peer_id,
	}))

	# Tell them about all the other connected peers.
	for other_peer_id in _id_map:
		var other_session_id = _id_map[other_peer_id]
		if other_session_id == presence.session_id or other_session_id == _my_session_id:
			continue
		nakama_socket.send_match_state_async(match_id, meta_op_code, JSON.print({
			type = MetaMessageType.ASSIGN_PEER_ID,
			session_id = other_session_id,
			peer_id = other_peer_id,
		}), [presence])

func _on_nakama_socket_received_match_presence(event: NakamaRTAPI.MatchPresenceEvent) -> void:
	if event.match_id != match_id:
		return

	for presence in event.joins:
		if not _users.has(presence.session_id):
			_users[presence.session_id] = User.new(presence)

		# If we are the host, and they don't yet have a peer id, then let's
		# generate a new id for them and send all the necessary messages.
		if _my_peer_id == 1 and _users[presence.session_id].peer_id == 0:
			_host_add_peer(presence)

	for presence in event.leaves:
		if not _users.has(presence.session_id):
			continue

		var peer_id = _users[presence.session_id].peer_id

		_users.erase(presence.session_id)
		_id_map.erase(peer_id)

		multiplayer_peer.emit_signal("peer_disconnected", peer_id)

func _parse_json(data: String):
	var result = JSON.parse(data)
	if result.error != OK:
		return null
	var content = result.result
	if not content is Dictionary:
		return null
	return content

func _on_nakama_socket_received_match_state(data: NakamaRTAPI.MatchData) -> void:
	if data.match_id != match_id:
		return

	if data.op_code == meta_op_code:
		var content = _parse_json(data.data)
		if content == null:
			return
		var type = content['type']
		#print ("RECEIVED: ", content)

		if type == MetaMessageType.CLAIM_HOST:
			if _id_map.has(1):
				# @todo Can we mediate this dispute?
				push_error("User %s claiming to be host, when user %s has already claimed it" % [data.presence.session_id, _id_map[1]])
			else:
				_map_id_to_session(1, data.presence.session_id)
			return

		# Ensure that any meta messages are coming from the host!
		if data.presence.session_id != _id_map[1]:
			push_error("Received meta message from user %s who isn't the host: %s" % [data.presence.session_id, content])
			return

		if type == MetaMessageType.ASSIGN_PEER_ID:
			var session_id = content['session_id']
			var peer_id = content['peer_id']

			if _users.has(session_id) and _users[session_id].peer_id != 0:
				push_error("Attempting to assign peer id %s to %s which already has id %s" % [
					peer_id,
					session_id,
					_users[session_id].peer_id,
				])
				return

			_map_id_to_session(peer_id, session_id)

			if _my_session_id == session_id:
				match_state = MatchState.CONNECTED
				multiplayer_peer.initialize(peer_id)
				multiplayer_peer.set_connection_status(NetworkedMultiplayerPeer.CONNECTION_CONNECTED)
				emit_signal("match_joined")
				multiplayer_peer.emit_signal("peer_connected", 1)
			else:
				multiplayer_peer.emit_signal("peer_connected", peer_id)
		else:
			nakama_socket.logger.error("Received meta message with unknown type: %s" % type)
	elif data.op_code == rpc_op_code:
		if not _users.has(data.presence.session_id):
			return
		var from_peer_id = _users[data.presence.session_id].peer_id
		multiplayer_peer.deliver_packet(data.binary_data, from_peer_id)

func _on_multiplayer_peer_packet_generated(peer_id: int, buffer: PoolByteArray, _transfer_mode: int) -> void:
	if match_state == MatchState.CONNECTED:
		var target_presences = null
		if peer_id > 0:
			if not _id_map.has(peer_id):
				push_error("Attempting to send RPC to unknown peer id: %s" % peer_id)
				return
			target_presences = [ _users[_id_map[peer_id]].presence ]
		nakama_socket.send_match_state_raw_async(match_id, rpc_op_code, buffer, target_presences)
	else:
		push_error("RPC sent while the NakamaMultiplayerBridge isn't connected!")
