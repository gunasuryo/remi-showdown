extends Node2D

const MODE_SELECT: String = "res://Scene/mode_select.tscn"

var turn:int = 1
var cardTurn:int = 0
var cardActed:int = 0
var targetCard
var currentCard
var currentSuit:bool
var skillTarget
var blackCards
var redCards
var cardPos:int
var targetSuit:bool
var targetSuitCards
var cardMarkers
var rng = RandomNumberGenerator.new()
var turnRNG = rng.randi_range(0, 1)
var boxSize:int

func _ready():
	blackCards = $CardsBlack.get_children()
	redCards = $CardsRed.get_children()
	cardPos = 0
	cardTurn = 1
	cardActed = -1
	if turnRNG == 1:
		$Coin.modulate = Color(1,0,0)
		currentSuit = false
	else:
		$Coin.modulate = Color(0,0,0)
		currentSuit = true
	set_cards_position()
	select_card()

func set_cards_position():
	blackCards = $CardsBlack.get_children()
	redCards = $CardsRed.get_children()
	boxSize = (blackCards.size() + redCards.size())/2
	print('box size now: ', boxSize)
	var xPos = 0
	var xPosSpace = 800
	var yPos = 1000
	for i in blackCards:
		i.global_position.x = $CardStartMarker.position.x + xPos*xPosSpace
		i.global_position.y = $CardStartMarker.position.y 
		xPos += 1
	xPos = 0
	for i in redCards:
		i.global_position.x = $CardStartMarker.position.x + xPos*xPosSpace
		i.global_position.y = $CardStartMarker.position.y + yPos
		xPos += 1
#	for i in redCards:
#		i.position = $CardMarkers/Marker2D3.position
		
func select_card():

	process_card()
	update_labels()
	check_alive()
	check_winner()
	print("> next turn <")

func process_card():
	cardActed += 1
	if cardActed >= 2:
		cardActed = 0
		cardPos += 1
		print('')
		print('---> changed box <---')
		cardTurn += 1
		turnRNG = rng.randi_range(0, 1)
		if turnRNG == 1:
			$Coin.modulate = Color(1,0,0)
			currentSuit = false
		else:
			$Coin.modulate = Color(0,0,0)
			currentSuit = true
		if cardPos >= boxSize:
			cardPos = 0
	print('')
	print('card pos: ', cardPos)
	print('rng: ', turnRNG)
	currentSuit = !currentSuit
	if currentSuit == false:
		currentCard = blackCards[cardPos]
		targetCard = redCards[cardPos]
	else:
		currentCard = redCards[cardPos]
		targetCard = blackCards[cardPos]
	if currentCard == null:
		print('target card: (already dead)', currentCard)
	else:	
		print('current card: ','[', currentCard.suitName, currentCard.cardClassName,']')
	if targetCard == null:
		print('target card: (already dead)', targetCard)
	else:
		print('target card: ', targetCard.suitName, targetCard.cardClassName)

func update_labels():
	$BoxLabel.text = str('Box: ',cardPos)
	$TurnLabel.text = str('Turn: ',cardTurn)
	$StatusLabel1.text = str('red cards', redCards)
	$StatusLabel2.text = str('black cards', blackCards)
	
func check_alive():
	if currentCard != null:
		if (currentCard.alive == true):
			print("activating", currentCard.suitName,currentCard.cardClassName)
			currentCard.battleBtnVisible = true
		else:
			select_card()
	else:
		select_card()
	
func check_winner():
	if redCards == null:
		print("Black wins!!!!!!!!!!!")
		$StatusLabel3.text = "Black wins"
		show_game_over("Black wins!")
	elif blackCards == null:
		print("Red wins!!!!!!!!!!!!!")
		$StatusLabel3.text = "Red wins"
		show_game_over("Red wins!")

func show_game_over(result: String) -> void:
	$CanvasLayer/GameOverPanel/VBoxContainer/ResultLabel.text = result
	$CanvasLayer/GameOverPanel.visible = true

func _on_menu_btn_pressed() -> void:
	get_tree().change_scene_to_file(MODE_SELECT)

func _on_again_btn_pressed() -> void:
	get_tree().reload_current_scene()
			
func select_skill_target(targetSuitSelected):
#if targeting ally
	if targetSuitSelected == false : 
		targetSuitCards = blackCards
	else:
		targetSuitCards = redCards
		
	for i in targetSuitCards:
		if i != null:
			i.targetBtnVisible = true
		
func check_if_dead(checkedCard):
	if checkedCard.alive == false:
		print(checkedCard.suitName, checkedCard.cardClassName, " is now dead")
#		checkedCard.global_position = $Deadmarker.position
		checkedCard.queue_free()
		checkedCard = null
		set_cards_position()
#		if blackCards.size() == redCards.size():
#			set_cards_position()
		

func attack_direct(attack):
	currentCard.card_acted()
	if targetCard != null:
		print("attacking ", targetCard.suitName, targetCard.cardClassName)
		targetCard.hit(attack)
		print('attack power:',attack)
		check_if_dead(targetCard)
	select_card()

func card_skill(skillTargetCard):
	currentCard.card_acted()
	currentCard.do_skill(skillTargetCard)
	check_if_dead(skillTargetCard)
	select_card()
	
	
func _on_ace_attack_pressed(attack):
	attack_direct(attack)
func _on_jack_attack_pressed(attack):
	attack_direct(attack)
func _on_queen_attack_pressed(attack):
	attack_direct(attack)
func _on_ace_skill_pressed():
	print("ace shielding")
	print("select ally:")
	targetSuit = currentSuit
	select_skill_target(targetSuit)
func _on_jack_skill_pressed():
	print("jack shooting")
	print("select enemy:")
	targetSuit = !currentSuit
	select_skill_target(targetSuit)
func _on_queen_skill_pressed():
	print("queen healing")
	print("select ally:")
	targetSuit = currentSuit
	select_skill_target(targetSuit)

func target_chosen(cardIndex):
	print(cardIndex.suitName, cardIndex.cardClassName)
	skillTarget = cardIndex
	card_skill(skillTarget)
	for i in blackCards:
		if i == null:
			continue
		i.targetBtnVisible = false
	for i in redCards:
		if i == null:
			continue
		i.targetBtnVisible = false
		
func _on_ace_target_pressed(cardIndex):
	target_chosen(cardIndex)
func _on_jack_target_pressed(cardIndex):
	target_chosen(cardIndex)
func _on_queen_target_pressed(cardIndex):
	target_chosen(cardIndex)
func _on_king_attack_pressed(attack):
	attack_direct(attack)
func _on_king_skill_pressed():
	print("king healing")
	print("select ally:")
	targetSuit = currentSuit
	select_skill_target(targetSuit)
func _on_king_target_pressed(cardIndex):
	target_chosen(cardIndex)
