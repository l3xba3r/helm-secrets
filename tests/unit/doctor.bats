#!/usr/bin/env bats

load '../lib/helper'
load '../bats/extensions/bats-support/load'
load '../bats/extensions/bats-assert/load'
load '../bats/extensions/bats-file/load'

@test "doctor: helm secrets --help lists doctor" {
    run "${HELM_BIN}" secrets --help
    assert_success
    assert_output --partial 'doctor  Check the helm-secrets setup'
}

@test "doctor: healthy setup passes" {
    run "${HELM_BIN}" secrets doctor
    assert_success
    assert_output --partial 'helm-secrets doctor'
    assert_output --partial '[ OK ] helm-secrets '
    assert_output --partial 'Summary: 0 failed'
}

@test "doctor: reports the installed plugins" {
    run "${HELM_BIN}" secrets doctor
    assert_success

    if helm_version_greater_or_equal_than 4.0.0; then
        assert_output --partial "[ OK ] plugin 'secrets' "
        assert_output --partial "[ OK ] plugin 'secrets-getter' "
        assert_output --partial "[ OK ] plugin 'secrets-post-renderer' "
    else
        assert_output --partial "[ OK ] plugin 'secrets' "
    fi
}

@test "doctor: reports the backend version" {
    if ! is_backend "sops" && ! is_backend "vals"; then
        skip
    fi

    run "${HELM_BIN}" secrets doctor
    assert_success
    assert_output --partial "[INFO] backend '${HELM_SECRETS_BACKEND}'"
    assert_output --regexp "\[ OK \] ${HELM_SECRETS_BACKEND} [0-9]+\.[0-9]+\.[0-9]+"
}

@test "doctor: fails if the sops binary is missing" {
    if ! is_backend "sops"; then
        skip
    fi

    run env HELM_SECRETS_SOPS_PATH="${TEST_TEMP_DIR}/does-not-exist" WSLENV="HELM_SECRETS_SOPS_PATH:${WSLENV}" \
        "${HELM_BIN}" secrets doctor
    assert_failure
    # Windows shells may rewrite the path (e.g. /tmp -> C:/Users/.../Temp), so only match its ends
    assert_output --regexp "\[FAIL\] sops binary '[^']*does-not-exist' not found in PATH"
    assert_output --partial 'Summary: 1 failed'
}

@test "doctor: fails if the vals binary is missing" {
    if ! is_backend "vals"; then
        skip
    fi

    run env HELM_SECRETS_VALS_PATH="${TEST_TEMP_DIR}/does-not-exist" WSLENV="HELM_SECRETS_VALS_PATH:${WSLENV}" \
        "${HELM_BIN}" secrets doctor
    assert_failure
    assert_output --regexp "\[FAIL\] vals binary '[^']*does-not-exist' not found in PATH"
}

@test "doctor: fails if SOPS_AGE_KEY_FILE does not exist" {
    if ! is_backend "sops"; then
        skip
    fi

    run env SOPS_AGE_KEY_FILE="${TEST_TEMP_DIR}/missing-keys.txt" WSLENV="SOPS_AGE_KEY_FILE:${WSLENV}" \
        "${HELM_BIN}" secrets doctor
    assert_failure
    assert_output --regexp "\[FAIL\] age: SOPS_AGE_KEY_FILE is set, but '[^']*missing-keys\.txt' does not exist"
}

@test "doctor: accepts an existing SOPS_AGE_KEY_FILE" {
    if ! is_backend "sops"; then
        skip
    fi

    run env SOPS_AGE_KEY_FILE="$(_winpath "${TEST_TEMP_DIR}/assets/age/key.txt")" WSLENV="SOPS_AGE_KEY_FILE:${WSLENV}" \
        "${HELM_BIN}" secrets doctor
    assert_success
    assert_output --partial '[ OK ] age: SOPS_AGE_KEY_FILE points to an existing file'
}

@test "doctor: never prints key material" {
    if ! is_backend "sops"; then
        skip
    fi

    run env SOPS_AGE_KEY="AGE-SECRET-KEY-DOCTOR-MUST-NOT-PRINT-THIS" WSLENV="SOPS_AGE_KEY:${WSLENV}" \
        "${HELM_BIN}" secrets doctor
    assert_success
    assert_output --partial '[ OK ] age: SOPS_AGE_KEY is set'
    refute_output --partial 'DOCTOR-MUST-NOT-PRINT-THIS'
}

@test "doctor: warns if HELM_SECRETS_ALLOWED_BACKENDS is unset inside Argo CD" {
    run env ARGOCD_APP_NAME=doctor WSLENV="ARGOCD_APP_NAME:${WSLENV}" "${HELM_BIN}" secrets doctor
    assert_success
    assert_output --partial '[WARN] HELM_SECRETS_ALLOWED_BACKENDS is not set inside Argo CD'
}

@test "doctor: reports HELM_SECRETS_ALLOWED_BACKENDS" {
    if ! is_backend "sops" && ! is_backend "vals"; then
        skip
    fi

    run env HELM_SECRETS_ALLOWED_BACKENDS=sops,vals WSLENV="HELM_SECRETS_ALLOWED_BACKENDS:${WSLENV}" \
        "${HELM_BIN}" secrets doctor
    assert_success
    assert_output --partial '[ OK ] HELM_SECRETS_ALLOWED_BACKENDS=sops,vals'
}
