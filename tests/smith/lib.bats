load helper

lib() { . "$S/lib.sh"; }

@test "run_backend_defaults_to_herdr" {
	write_run '{"tasks":{}}'
	lib
	[ "$(run_backend)" = herdr ]
}

@test "run_backend_reads_field" {
	write_run '{"backend":"herdr-app","tasks":{}}'
	lib
	[ "$(run_backend)" = herdr-app ]
}

@test "hc_state_maps_status" {
	stub_reply hc get.t21 '{"state":"live","status":{"state":"blocked"}}'
	lib
	[ "$(hc_state t21)" = blocked ]
}

@test "hc_state_finished_is_gone" {
	stub_reply hc get.t21 '{"state":"finished"}'
	lib
	[ "$(hc_state t21)" = gone ]
}

@test "hc_state_missing_is_gone" {
	stub_reply hc get.t21 '{"error":"no such terminal"}' 1
	lib
	[ "$(hc_state t21)" = gone ]
}

@test "hc_state_no_state_is_gone" {
	lib
	[ "$(hc_state t21)" = gone ]
}

@test "hc_state_null_status_is_idle" {
	stub_reply hc get.t21 '{"state":"live","status":null}'
	lib
	[ "$(hc_state t21)" = idle ]
}

@test "hc_status_ms_and_turn_default_to_zero" {
	lib
	[ "$(hc_status_ms t21)" = 0 ]
	[ "$(hc_turn t21)" = 0 ]
	stub_reply hc get.t21 '{"state":"live","status_ms":1234,"turn":5}'
	[ "$(hc_status_ms t21)" = 1234 ]
	[ "$(hc_turn t21)" = 5 ]
}

@test "helpers_survive_set_e" {
	stub_reply hc get.t21 '{"error":"x"}' 1
	lib
	set -e
	hc_state t21 >/dev/null
	hc_status_ms t21 >/dev/null
	hc_turn t21 >/dev/null
}

@test "worker_hc_prefers_address" {
	write_run '{"tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21"},"102":{"id":"102","agent":"smith-102"}}}'
	lib
	[ "$(worker_hc 101)" = t21 ]
	[ "$(worker_hc 102)" = smith-102 ]
}
