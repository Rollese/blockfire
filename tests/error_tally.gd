class_name TestErrorTally
extends Logger
## Counts engine error reports (SCRIPT ERROR, push_error, ERR_* macros) while registered
## via OS.add_logger. The runner snapshots `count` around each test so a runtime error
## mid-test fails it — previously a script error after the first assertion passed silently.
## Warnings (push_warning) are deliberately not counted.

var count := 0


func _log_error(_function: String, _file: String, _line: int, _code: String,
		_rationale: String, _editor_notify: bool, error_type: int,
		_script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type != ERROR_TYPE_WARNING:
		count += 1
