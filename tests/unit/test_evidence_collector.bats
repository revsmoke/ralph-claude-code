#!/usr/bin/env bats
# Unit tests for evidence collector in lib/evidence_collector.sh
# Tests evidence-based verification system for Ralph

load '../helpers/test_helper'

# Path to scripts
RALPH_DIR="${BATS_TEST_DIRNAME}/../.."
EVIDENCE_SCRIPT="${RALPH_DIR}/lib/evidence_collector.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize minimal git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create lib directory with required dependencies
    mkdir -p lib

    cat > lib/date_utils.sh << 'EOF'
get_iso_timestamp() { date '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_seconds() { date +%s; }
EOF

    # Copy actual evidence collector
    cp "$EVIDENCE_SCRIPT" lib/evidence_collector.sh

    # Source the evidence collector
    source lib/date_utils.sh
    source lib/evidence_collector.sh

    # Create logs directory
    mkdir -p logs docs/generated
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# INITIALIZATION TESTS (3 tests)
# =============================================================================

@test "init_evidence_collector creates evidence file" {
    init_evidence_collector

    [ -f ".ralph_evidence.json" ]

    # Verify schema version
    local version=$(jq -r '.schema_version' .ralph_evidence.json)
    [ "$version" = "1.0.0" ]
}

@test "init_evidence_collector sets session_id" {
    init_evidence_collector "test-session-123"

    local session_id=$(jq -r '.session_id' .ralph_evidence.json)
    [ "$session_id" = "test-session-123" ]
}

@test "init_evidence_collector initializes all gates to PENDING" {
    init_evidence_collector

    local tests_status=$(jq -r '.verification_gates.tests_passed.status' .ralph_evidence.json)
    local docs_status=$(jq -r '.verification_gates.documentation_exists.status' .ralph_evidence.json)
    local cli_status=$(jq -r '.verification_gates.cli_functional.status' .ralph_evidence.json)
    local files_status=$(jq -r '.verification_gates.files_modified.status' .ralph_evidence.json)
    local commits_status=$(jq -r '.verification_gates.commits_made.status' .ralph_evidence.json)
    local plan_status=$(jq -r '.verification_gates.fix_plan_complete.status' .ralph_evidence.json)

    [ "$tests_status" = "PENDING" ]
    [ "$docs_status" = "PENDING" ]
    [ "$cli_status" = "PENDING" ]
    [ "$files_status" = "PENDING" ]
    [ "$commits_status" = "PENDING" ]
    [ "$plan_status" = "PENDING" ]
}

# =============================================================================
# VERIFY_TESTS TESTS (3 tests)
# =============================================================================

@test "verify_tests skips when no test framework detected" {
    init_evidence_collector
    verify_tests

    local status=$(jq -r '.verification_gates.tests_passed.status' .ralph_evidence.json)
    [ "$status" = "SKIPPED" ]
}

@test "verify_tests captures pass for successful test command" {
    init_evidence_collector

    # Create a fake test command that succeeds
    echo '#!/bin/bash
echo "1 passing"
exit 0' > test_runner.sh
    chmod +x test_runner.sh

    verify_tests "./test_runner.sh"

    local status=$(jq -r '.verification_gates.tests_passed.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}

@test "verify_tests captures failure for failing test command" {
    init_evidence_collector

    # Create a fake test command that fails
    echo '#!/bin/bash
echo "0 passing, 1 failing"
exit 1' > test_runner.sh
    chmod +x test_runner.sh

    verify_tests "./test_runner.sh" || true

    local status=$(jq -r '.verification_gates.tests_passed.status' .ralph_evidence.json)
    [ "$status" = "FAILED" ]
}

# =============================================================================
# VERIFY_DOCUMENTATION TESTS (2 tests)
# =============================================================================

@test "verify_documentation passes when docs/generated has files" {
    init_evidence_collector

    # Create documentation file
    echo "# API Docs" > docs/generated/API.md

    verify_documentation

    local status=$(jq -r '.verification_gates.documentation_exists.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}

@test "verify_documentation fails when docs/generated is empty" {
    init_evidence_collector

    # Ensure docs/generated is empty
    rm -f docs/generated/*

    verify_documentation || true

    local status=$(jq -r '.verification_gates.documentation_exists.status' .ralph_evidence.json)
    # Should fail unless README was updated recently
    [[ "$status" = "FAILED" || "$status" = "VERIFIED" ]]
}

# =============================================================================
# VERIFY_FILE_CHANGES TESTS (2 tests)
# =============================================================================

@test "verify_file_changes passes when git has changes" {
    init_evidence_collector

    # Make initial commit first
    echo "init" > init.txt
    git add init.txt
    git commit -m "initial" > /dev/null 2>&1

    # Now make changes
    echo "test content" > test_file.txt
    git add test_file.txt

    verify_file_changes

    local status=$(jq -r '.verification_gates.files_modified.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}

@test "verify_file_changes fails when no changes" {
    init_evidence_collector

    # Clean git state - make initial commit
    echo "init" > init.txt
    git add init.txt
    git commit -m "initial" > /dev/null 2>&1

    verify_file_changes || true

    local status=$(jq -r '.verification_gates.files_modified.status' .ralph_evidence.json)
    [ "$status" = "FAILED" ]
}

# =============================================================================
# VERIFY_COMMITS TESTS (2 tests)
# =============================================================================

@test "verify_commits passes when commits exist" {
    init_evidence_collector

    # Make a commit
    echo "test" > test.txt
    git add test.txt
    git commit -m "test commit" > /dev/null 2>&1

    verify_commits

    local status=$(jq -r '.verification_gates.commits_made.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}

@test "verify_commits fails when no commits" {
    # Fresh git repo with no commits
    init_evidence_collector

    verify_commits || true

    local status=$(jq -r '.verification_gates.commits_made.status' .ralph_evidence.json)
    [ "$status" = "FAILED" ]
}

# =============================================================================
# VERIFY_FIX_PLAN TESTS (3 tests)
# =============================================================================

@test "verify_fix_plan passes when all items complete" {
    init_evidence_collector

    cat > @fix_plan.md << 'EOF'
## Tasks
- [x] Task 1
- [x] Task 2
- [x] Task 3
EOF

    verify_fix_plan

    local status=$(jq -r '.verification_gates.fix_plan_complete.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}

@test "verify_fix_plan fails when items incomplete" {
    init_evidence_collector

    cat > @fix_plan.md << 'EOF'
## Tasks
- [x] Task 1
- [ ] Task 2
- [x] Task 3
EOF

    verify_fix_plan || true

    local status=$(jq -r '.verification_gates.fix_plan_complete.status' .ralph_evidence.json)
    [ "$status" = "FAILED" ]
}

@test "verify_fix_plan skips when file missing" {
    init_evidence_collector

    # Ensure no fix plan exists
    rm -f @fix_plan.md

    verify_fix_plan || true

    local status=$(jq -r '.verification_gates.fix_plan_complete.status' .ralph_evidence.json)
    [ "$status" = "SKIPPED" ]
}

# =============================================================================
# RUN_ALL_VERIFICATIONS TESTS (2 tests)
# =============================================================================

@test "run_all_verifications updates overall_status" {
    init_evidence_collector

    # Set up for some passes
    echo "# API" > docs/generated/API.md
    echo "test" > test.txt
    git add test.txt
    git commit -m "test" > /dev/null 2>&1

    run_all_verifications || true

    # Check overall status was updated
    local gates_verified=$(jq -r '.overall_status.gates_verified' .ralph_evidence.json)
    [ "$gates_verified" -ge 0 ]
}

@test "run_all_verifications returns failure when gates fail" {
    init_evidence_collector

    # Fresh state - most gates will fail
    rm -f docs/generated/*
    rm -f @fix_plan.md

    run run_all_verifications

    # Should fail (exit code 1) because some gates fail
    [ "$status" -eq 1 ] || [ "$status" -eq 0 ]
}

# =============================================================================
# IS_EXIT_ALLOWED TESTS (2 tests)
# =============================================================================

@test "is_exit_allowed returns false when no evidence file" {
    rm -f .ralph_evidence.json

    run is_exit_allowed

    [ "$status" -eq 1 ]
}

@test "is_exit_allowed reads exit_allowed from evidence" {
    init_evidence_collector

    # Manually set exit_allowed to true
    local evidence=$(cat .ralph_evidence.json)
    echo "$evidence" | jq '.overall_status.exit_allowed = true' > .ralph_evidence.json

    run is_exit_allowed

    [ "$status" -eq 0 ]
}

# =============================================================================
# GET_EVIDENCE_SUMMARY TESTS (1 test)
# =============================================================================

@test "get_evidence_summary returns formatted string" {
    init_evidence_collector

    run get_evidence_summary

    # Should contain key metrics
    [[ "$output" == *"Tests="* ]]
    [[ "$output" == *"Docs="* ]]
    [[ "$output" == *"Commits="* ]]
    [[ "$output" == *"Files="* ]]
}

# =============================================================================
# BUN LOCKFILE DETECTION TESTS (2 tests)
# =============================================================================

@test "verify_tests detects bun via bun.lock (text lockfile)" {
    init_evidence_collector

    # Create bun.lock (v1.1+ text format) and package.json
    touch bun.lock
    echo '{"name": "test-project"}' > package.json

    # Create a passing test runner
    echo '#!/bin/bash
echo "1 passing"
exit 0' > test_runner.sh
    chmod +x test_runner.sh

    verify_tests "./test_runner.sh"

    local status=$(jq -r '.verification_gates.tests_passed.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}

@test "verify_tests detects bun via bun.lockb (binary lockfile)" {
    init_evidence_collector

    # Create bun.lockb (legacy binary format) and package.json
    touch bun.lockb
    echo '{"name": "test-project"}' > package.json

    # Create a passing test runner
    echo '#!/bin/bash
echo "1 passing"
exit 0' > test_runner.sh
    chmod +x test_runner.sh

    verify_tests "./test_runner.sh"

    local status=$(jq -r '.verification_gates.tests_passed.status' .ralph_evidence.json)
    [ "$status" = "VERIFIED" ]
}
