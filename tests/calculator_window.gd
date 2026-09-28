extends SceneTree
## Pure-logic test for calculator_window.gd's evaluate_expression() - no
## scene, no UI, no network. Godot's own Expression class does the actual
## arithmetic; this confirms the wrapping (success/failure shape, number
## formatting) behaves the way the window's own UI relies on.
## Run: "$GODOT" --headless --path . --script res://tests/calculator_window.gd

const CalculatorWindow := preload("res://scripts/calculator_window.gd")


func _initialize() -> void:
	var r1 := CalculatorWindow.evaluate_expression("2+2")
	print("SMOKE 2+2 evaluates ok: ", r1["ok"])
	print("SMOKE 2+2 gives 4: ", r1["text"] == "4")

	var r2 := CalculatorWindow.evaluate_expression("10/4")
	print("SMOKE 10/4 gives 2.5: ", r2["ok"] and r2["text"] == "2.5")

	var r3 := CalculatorWindow.evaluate_expression("3*3-1")
	print("SMOKE 3*3-1 respects operator precedence (8, not 6): ", r3["ok"] and r3["text"] == "8")

	var r4 := CalculatorWindow.evaluate_expression("0")
	print("SMOKE zero trims to a bare '0', not '0.000000': ", r4["ok"] and r4["text"] == "0")

	var r5 := CalculatorWindow.evaluate_expression("100")
	print("SMOKE a whole number trims trailing zeros without eating real digits: ", r5["ok"] and r5["text"] == "100")

	var r6 := CalculatorWindow.evaluate_expression("2+")
	print("SMOKE an incomplete expression fails cleanly: ", not r6["ok"])

	var r7 := CalculatorWindow.evaluate_expression("2 + abc")
	print("SMOKE an unparseable expression fails cleanly, not a crash: ", not r7["ok"])

	print("SMOKE a failed evaluation carries no misleading text: ", r6["text"] == "" and r7["text"] == "")

	quit()
