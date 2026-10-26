class_name OddSocketsMessageSizeValidator
extends RefCounted
## Client-side message size validation. The platform rejects messages over
## 32KB (UTF-8 bytes); checking before send gives games a friendly error
## instead of a dropped publish.

const MAX_MESSAGE_BYTES: int = 32 * 1024


## Returns `{ "size_bytes": int, "max_bytes": int, "valid": bool, "percent": float }`
## for the UTF-8 encoding of [param message].
static func get_message_size_info(message: String) -> Dictionary:
	var size := message.to_utf8_buffer().size()
	return {
		"size_bytes": size,
		"max_bytes": MAX_MESSAGE_BYTES,
		"valid": size <= MAX_MESSAGE_BYTES,
		"percent": float(size) * 100.0 / float(MAX_MESSAGE_BYTES),
	}


## True when [param message] fits inside the platform limit.
static func is_valid(message: String) -> bool:
	return message.to_utf8_buffer().size() <= MAX_MESSAGE_BYTES
