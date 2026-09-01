#!/usr/bin/env bash

set -Eeuo pipefail

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/shell/linux-alo.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

run_case() {
    local name="$1"
    local expected_status="$2"
    local expected_codename="$3"
    local id="$4"
    local version_id="$5"
    local version_codename="${6:-}"
    local os_release_file="$test_root/${name}.os-release"
    local output
    local status

    {
        printf 'ID=%q\n' "$id"
        printf 'VERSION_ID=%q\n' "$version_id"
        printf 'VERSION_CODENAME=%q\n' "$version_codename"
    } > "$os_release_file"

    if output=$(bash -c '
        PATH="$1"
        export PATH
        source "$2"
        detect_os "$3"
        check_supported_debian_version
    ' bash "$test_root" "$script_path" "$os_release_file" 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne "$expected_status" ]; then
        printf 'FAIL: %s expected exit %s, got %s\n%s\n' \
            "$name" "$expected_status" "$status" "$output" >&2
        return 1
    fi

    if [ -n "$expected_codename" ] && [[ "$output" != *"代号：${expected_codename}"* ]]; then
        printf 'FAIL: %s expected codename %s\n%s\n' \
            "$name" "$expected_codename" "$output" >&2
        return 1
    fi

    printf 'PASS: %s\n' "$name"
}

run_case "debian-11" 0 "bullseye" "debian" "11"
run_case "debian-12" 0 "bookworm" "debian" "12"
run_case "debian-13" 0 "trixie" "debian" "13"
run_case "debian-10" 1 "" "debian" "10" "buster"
run_case "ubuntu-24.04" 1 "" "ubuntu" "24.04" "noble"
run_case "other-os" 1 "" "fedora" "40" "forty"

printf 'All linux-alo OS detection cases passed.\n'
