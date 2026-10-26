class_name OddSocketsConfig
extends RefCounted
## Connection configuration for [OddSocketsClient].
##
## Authenticate with either [member api_key] (server builds, tools, trusted
## environments) or a short-lived minted token (player devices — keep the key
## off the device). When [member api_key] is empty and a token provider is
## wired on the client, the client requests a token before every (re)connect.

## API key authentication. Leave empty for token-based auth.
var api_key: String = ""

## Stable user id this connection represents (required).
var user_id: String = ""

## Token auth: `{ "token": String, "expires_at": String }` where expires_at is
## ISO 8601 (e.g. "2026-10-26T12:00:00Z"). Usually supplied by a token
## provider rather than set directly.
var token: Dictionary = {}

## Override the connection endpoint. Leave empty for the production default.
var manager_url: String = ""

## Pin a specific worker URL, skipping discovery. Testing/ops only.
var worker_url: String = ""

## Identifier reported during discovery; defaults to "godot-<user_id>".
var client_identifier: String = ""

## Seconds before token expiry at which a fresh token is requested.
var token_refresh_lead_seconds: float = 60.0

## Reconnect automatically after an unexpected disconnect.
var auto_reconnect: bool = true

## Maximum automatic reconnect attempts before giving up (0 = unlimited).
var max_reconnect_attempts: int = 10

## Base delay between reconnect attempts, in seconds (doubles per attempt,
## capped at 30s).
var reconnect_delay_seconds: float = 1.0

## Default timeout for request/response calls, in seconds.
var request_timeout_seconds: float = 10.0
