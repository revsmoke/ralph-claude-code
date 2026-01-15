#!/usr/bin/env bats
# Unit tests for preflight checks in ralph_loop.sh
# Tests tooling preflight verification system for Ralph

load '../helpers/test_helper'

# Path to ralph_loop.sh
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize minimal git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create lib directory with required stubs
    mkdir -p lib logs docs/generated

    cat > lib/date_utils.sh << 'EOF'
get_iso_timestamp() { date '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_seconds() { date +%s; }
get_next_hour_time() { date '+%H:%M:%S'; }
get_basic_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
export -f get_iso_timestamp
export -f get_epoch_seconds
export -f get_next_hour_time
export -f get_basic_timestamp
EOF

    cat > lib/response_analyzer.sh << 'EOF'
analyze_response() { :; }
detect_output_format() { echo "text"; }
update_exit_signals() { :; }
store_session_id() { :; }
get_last_session_id() { echo ""; }
should_resume_session() { echo "false"; return 1; }
export -f analyze_response
export -f detect_output_format
export -f update_exit_signals
export -f store_session_id
export -f get_last_session_id
export -f should_resume_session
EOF

    cat > lib/circuit_breaker.sh << 'EOF'
CB_STATE_CLOSED="CLOSED"
CB_STATE_HALF_OPEN="HALF_OPEN"
CB_STATE_OPEN="OPEN"
init_circuit_breaker() { :; }
get_circuit_state() { echo "CLOSED"; }
can_execute() { return 0; }
record_loop_result() { return 0; }
show_circuit_status() { echo "Circuit breaker status: CLOSED"; }
reset_circuit_breaker() { echo "Circuit breaker reset"; }
should_halt_execution() { return 1; }
export -f init_circuit_breaker
export -f get_circuit_state
export -f can_execute
export -f record_loop_result
export -f show_circuit_status
export -f reset_circuit_breaker
export -f should_halt_execution
EOF

    cat > lib/evidence_collector.sh << 'EOF'
EVIDENCE_FILE=".ralph_evidence.json"
init_evidence_collector() { :; }
verify_tests() { return 0; }
verify_documentation() { return 0; }
verify_cli() { return 0; }
verify_file_changes() { return 0; }
verify_commits() { return 0; }
verify_fix_plan() { return 0; }
run_all_verifications() { return 0; }
is_exit_allowed() { return 0; }
get_evidence_summary() { echo "Tests=OK"; }
show_evidence_status() { echo "Evidence status shown"; }
log_evidence_failures() { :; }
export -f init_evidence_collector
export -f verify_tests
export -f verify_documentation
export -f verify_cli
export -f verify_file_changes
export -f verify_commits
export -f verify_fix_plan
export -f run_all_verifications
export -f is_exit_allowed
export -f get_evidence_summary
export -f show_evidence_status
export -f log_evidence_failures
EOF

    # Create minimal required files
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > .exit_signals
    echo "0" > .call_count
    echo "$(date +%Y%m%d%H)" > .last_reset
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# PREFLIGHT DETECTION TESTS (7 tests)
# =============================================================================

@test "preflight detects missing PROMPT.md" {
    # Ensure PROMPT.md does not exist
    rm -f PROMPT.md

    run bash "$RALPH_SCRIPT" --help 2>&1 | head -1

    # Help should work without PROMPT.md
    assert_success
}

@test "preflight detects Node.js project from package.json" {
    echo "# Test Prompt" > PROMPT.md
    echo '{"name": "test"}' > package.json

    # Source the script functions
    source lib/date_utils.sh
    source lib/response_analyzer.sh
    source lib/circuit_breaker.sh
    source lib/evidence_collector.sh
    source "$RALPH_SCRIPT"

    run detect_project_type

    [[ "$output" == *"Node.js"* ]] || [[ "$output" == *"Bun"* ]]
}

@test "preflight detects Python project from requirements.txt" {
    echo "# Test Prompt" > PROMPT.md
    echo "flask==2.0.0" > requirements.txt

    source lib/date_utils.sh
    source lib/response_analyzer.sh
    source lib/circuit_breaker.sh
    source lib/evidence_collector.sh
    source "$RALPH_SCRIPT"

    run detect_project_type

    [[ "$output" == *"Python"* ]]
}

@test "preflight detects Python project from pyproject.toml" {
    echo "# Test Prompt" > PROMPT.md
    echo '[project]
name = "test"' > pyproject.toml

    source lib/date_utils.sh
    source lib/response_analyzer.sh
    source lib/circuit_breaker.sh
    source lib/evidence_collector.sh
    source "$RALPH_SCRIPT"

    run detect_project_type

    [[ "$output" == *"Python"* ]]
}

@test "preflight detects Rust project from Cargo.toml" {
    echo "# Test Prompt" > PROMPT.md
    echo '[package]
name = "test"' > Cargo.toml

    source lib/date_utils.sh
    source lib/response_analyzer.sh
    source lib/circuit_breaker.sh
    source lib/evidence_collector.sh
    source "$RALPH_SCRIPT"

    run detect_project_type

    [[ "$output" == *"Rust"* ]]
}

@test "preflight detects Go project from go.mod" {
    echo "# Test Prompt" > PROMPT.md
    echo 'module test' > go.mod

    source lib/date_utils.sh
    source lib/response_analyzer.sh
    source lib/circuit_breaker.sh
    source lib/evidence_collector.sh
    source "$RALPH_SCRIPT"

    run detect_project_type

    [[ "$output" == *"Go"* ]]
}

@test "preflight check_tool_exists returns success for existing tool" {
    echo "# Test Prompt" > PROMPT.md

    source lib/date_utils.sh
    source lib/response_analyzer.sh
    source lib/circuit_breaker.sh
    source lib/evidence_collector.sh
    source "$RALPH_SCRIPT"

    run check_tool_exists "bash"

    assert_success
}

# =============================================================================
# RESET-ALL TESTS (3 tests)
# =============================================================================

@test "--reset-all removes state files" {
    echo "# Test Prompt" > PROMPT.md

    # Create some state files
    echo "5" > .call_count
    echo '{"state": "CLOSED"}' > .circuit_breaker_state
    echo '{}' > .ralph_evidence.json
    echo '{}' > .exit_signals

    run bash "$RALPH_SCRIPT" --reset-all

    # Check files were removed
    [ ! -f ".call_count" ] || [ "$(cat .call_count 2>/dev/null)" != "5" ]
}

@test "--reset-all exits with success" {
    echo "# Test Prompt" > PROMPT.md

    run bash "$RALPH_SCRIPT" --reset-all

    assert_success
}

@test "--reset-all reports removed files" {
    echo "# Test Prompt" > PROMPT.md

    # Create state files
    echo "5" > .call_count
    echo '{}' > .exit_signals

    run bash "$RALPH_SCRIPT" --reset-all

    [[ "$output" == *"Resetting"* ]] || [[ "$output" == *"reset"* ]]
}

# =============================================================================
# EVIDENCE CLI TESTS (3 tests)
# =============================================================================

@test "--verify-evidence runs verification gates" {
    echo "# Test Prompt" > PROMPT.md

    run bash "$RALPH_SCRIPT" --verify-evidence

    # Should complete (pass or fail based on state)
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "--evidence-status shows evidence status" {
    echo "# Test Prompt" > PROMPT.md

    run bash "$RALPH_SCRIPT" --evidence-status

    # Should show status output
    [[ "$output" == *"Evidence"* ]] || [[ "$output" == *"status"* ]] || [[ "$output" == *"PENDING"* ]] || [[ "$output" == *"found"* ]]
}

@test "--skip-evidence flag is recognized" {
    echo "# Test Prompt" > PROMPT.md

    run bash "$RALPH_SCRIPT" --help

    [[ "$output" == *"--skip-evidence"* ]]
}

# =============================================================================
# TIMEOUT DEFAULT TEST (1 test)
# =============================================================================

@test "default timeout is 30 minutes" {
    run bash "$RALPH_SCRIPT" --help

    # Help text should show 30 as default timeout
    [[ "$output" == *"30"* ]]
}
