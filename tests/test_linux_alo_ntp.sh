#!/usr/bin/env bash

set -Eeuo pipefail

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/shell/linux-alo.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

run_case() {
    local case_name="$1"
    local expected_status="$2"
    local expected_output_pattern="$3"
    local unexpected_output_pattern="$4"
    local setup_fn="$5"
    local verify_fn="$6"

    local case_dir="$test_root/$case_name"
    local mock_bin="$case_dir/bin"
    local state_dir="$case_dir/state"
    local calls_log="$case_dir/calls.log"

    mkdir -p "$mock_bin" "$state_dir"
    touch "$calls_log"

    # 执行测试用例的前置环境配置
    "$setup_fn" "$mock_bin" "$state_dir"

    # 创建标准 mock: systemctl
    cat > "$mock_bin/systemctl" <<EOS
#!/usr/bin/env bash
set -eu
echo "systemctl \$*" >> "$calls_log"
state_dir="$state_dir"

action=""
args=()
for arg in "\$@"; do
    if [ -z "\$action" ] && [[ "\$arg" != -* ]]; then
        action="\$arg"
    elif [[ "\$arg" != -* ]]; then
        args+=("\$arg")
    fi
done

target="\${args[0]:-}"

case "\$action" in
    is-active)
        if [ -n "\$target" ] && [ -f "\$state_dir/active_\$target" ]; then
            exit 0
        else
            exit 1
        fi
        ;;
    list-unit-files)
        # 支持匹配 unit_*.service
        unit="\${target%%.service}.service"
        if [ -n "\$unit" ] && [ -f "\$state_dir/unit_\$unit" ]; then
            echo "\$unit enabled"
            exit 0
        fi
        exit 1
        ;;
    enable|start)
        if [ -n "\$target" ]; then
            service="\${target%%.service}"
            if [ -f "\$state_dir/fail_start_\$service" ]; then
                exit 1
            fi
            touch "\$state_dir/active_\$service"
            exit 0
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOS
    chmod +x "$mock_bin/systemctl"

    # 创建标准 mock: timedatectl
    cat > "$mock_bin/timedatectl" <<EOS
#!/usr/bin/env bash
set -eu
echo "timedatectl \$*" >> "$calls_log"
state_dir="$state_dir"

if [ "\${1:-}" = "show" ]; then
    if [ -f "\$state_dir/ntp_synchronized" ]; then
        echo "yes"
    else
        echo "no"
    fi
    exit 0
fi
exit 0
EOS
    chmod +x "$mock_bin/timedatectl"

    # 创建标准 mock: apt-get
    cat > "$mock_bin/apt-get" <<EOS
#!/usr/bin/env bash
set -eu
echo "apt-get \$*" >> "$calls_log"
state_dir="$state_dir"

pkg="\${@: -1}"
if [ -f "\$state_dir/fail_apt_\$pkg" ]; then
    exit 1
fi

touch "\$state_dir/unit_\${pkg}.service"
if [ ! -f "\$state_dir/fail_start_\${pkg}" ]; then
    touch "\$state_dir/active_\${pkg}"
fi
exit 0
EOS
    chmod +x "$mock_bin/apt-get"

    # 创建标准 mock: pgrep
    cat > "$mock_bin/pgrep" <<EOS
#!/usr/bin/env bash
set -eu
echo "pgrep \$*" >> "$calls_log"
state_dir="$state_dir"

proc="\${@: -1}"
if [ -f "\$state_dir/proc_\$proc" ]; then
    exit 0
fi
exit 1
EOS
    chmod +x "$mock_bin/pgrep"

    local output=""
    local status=0

    if output=$(bash -c '
        PATH="$1:$PATH"
        export PATH
        export SYSTEMD_MOCK=1
        source "$2"
        setup_ntp
    ' bash "$mock_bin" "$script_path" 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne "$expected_status" ]; then
        printf 'FAIL: %s expected exit %s, got %s\nOutput:\n%s\n' \
            "$case_name" "$expected_status" "$status" "$output" >&2
        return 1
    fi

    if [ -n "$expected_output_pattern" ] && [[ "$output" != *"$expected_output_pattern"* ]]; then
        printf 'FAIL: %s output missing expected pattern "%s"\nOutput:\n%s\n' \
            "$case_name" "$expected_output_pattern" "$output" >&2
        return 1
    fi

    if [ -n "$unexpected_output_pattern" ] && [[ "$output" == *"$unexpected_output_pattern"* ]]; then
        printf 'FAIL: %s output contained unexpected pattern "%s"\nOutput:\n%s\n' \
            "$case_name" "$unexpected_output_pattern" "$output" >&2
        return 1
    fi

    # 执行自定义调用验证
    if ! "$verify_fn" "$calls_log" "$state_dir"; then
        printf 'FAIL: %s custom verification failed\n' "$case_name" >&2
        return 1
    fi

    printf 'PASS: %s\n' "$case_name"
}

# -------------------------------------------------------------
# Case 1: 服务正在运行 (Active Service)
# -------------------------------------------------------------
setup_active_chrony() {
    local mock_bin="$1" state_dir="$2"
    touch "$state_dir/active_chrony"
}
verify_active_chrony() {
    local calls_log="$1" state_dir="$2"
    ! grep -q "apt-get" "$calls_log"
}

# -------------------------------------------------------------
# Case 2: Inactive OpenNTPd 正确判型，绝不误判为 ntp
# -------------------------------------------------------------
setup_inactive_openntpd() {
    local mock_bin="$1" state_dir="$2"
    touch "$state_dir/unit_openntpd.service"
    # 同时提供 openntpd 和 ntpd 两个二进制
    cat > "$mock_bin/openntpd" <<'EOS'
#!/bin/sh
exit 0
EOS
    chmod +x "$mock_bin/openntpd"
    cat > "$mock_bin/ntpd" <<'EOS'
#!/bin/sh
exit 0
EOS
    chmod +x "$mock_bin/ntpd"
}
verify_inactive_openntpd() {
    local calls_log="$1" state_dir="$2"
    # 必须启动 openntpd，绝不能启动 ntp
    grep -q "systemctl enable --now openntpd" "$calls_log" && \
    ! grep -q "enable --now ntp" "$calls_log" && \
    ! grep -q "apt-get" "$calls_log"
}

# -------------------------------------------------------------
# Case 3: 已装组件启动核验失败，必须阻断报错，不得谎报成功
# -------------------------------------------------------------
setup_start_failure() {
    local mock_bin="$1" state_dir="$2"
    touch "$state_dir/unit_chrony.service"
    touch "$state_dir/fail_start_chrony"
    cat > "$mock_bin/chronyd" <<'EOS'
#!/bin/sh
exit 0
EOS
    chmod +x "$mock_bin/chronyd"
}
verify_start_failure() {
    local calls_log="$1" state_dir="$2"
    grep -q "systemctl enable --now chrony" "$calls_log" && \
    ! grep -q "apt-get" "$calls_log"
}

# -------------------------------------------------------------
# Case 4: 干净环境无 NTP，成功安装并启动 chrony
# -------------------------------------------------------------
setup_clean_install_chrony() {
    local mock_bin="$1" state_dir="$2"
    # 无任何已存在 unit
}
verify_clean_install_chrony() {
    local calls_log="$1" state_dir="$2"
    grep -q "apt-get install -y chrony" "$calls_log" && \
    grep -q "systemctl enable --now chrony" "$calls_log" && \
    ! grep -q "apt-get install -y systemd-timesyncd" "$calls_log"
}

# -------------------------------------------------------------
# Case 5: chrony 失败，自动平滑回退到 systemd-timesyncd
# -------------------------------------------------------------
setup_chrony_fallback() {
    local mock_bin="$1" state_dir="$2"
    touch "$state_dir/fail_apt_chrony"
}
verify_chrony_fallback() {
    local calls_log="$1" state_dir="$2"
    grep -q "apt-get install -y chrony" "$calls_log" && \
    grep -q "apt-get install -y systemd-timesyncd" "$calls_log" && \
    grep -q "systemctl enable --now systemd-timesyncd" "$calls_log"
}

# -------------------------------------------------------------
# Case 6: 全部失败时坚决返回退出码 1
# -------------------------------------------------------------
setup_all_failed() {
    local mock_bin="$1" state_dir="$2"
    touch "$state_dir/fail_apt_chrony"
    touch "$state_dir/fail_apt_systemd-timesyncd"
}
verify_all_failed() {
    local calls_log="$1" state_dir="$2"
    grep -q "apt-get install -y chrony" "$calls_log" && \
    grep -q "apt-get install -y systemd-timesyncd" "$calls_log"
}

# -------------------------------------------------------------
# Case 7: timedatectl show NTPSynchronized=yes 时跳过安装
# -------------------------------------------------------------
setup_timedatectl_synced() {
    local mock_bin="$1" state_dir="$2"
    touch "$state_dir/ntp_synchronized"
}
verify_timedatectl_synced() {
    local calls_log="$1" state_dir="$2"
    ! grep -q "apt-get" "$calls_log"
}

# 运行所有用例
run_case "active_service" 0 "正在运行 (chrony)" "" setup_active_chrony verify_active_chrony
run_case "inactive_openntpd" 0 "openntpd 已成功启动" "ntp 已成功启动" setup_inactive_openntpd verify_inactive_openntpd
run_case "start_failure_aborts" 1 "已安装，但启动或状态核验失败" "已成功启动" setup_start_failure verify_start_failure
run_case "clean_install_chrony" 0 "chrony 安装并启动成功" "" setup_clean_install_chrony verify_clean_install_chrony
run_case "chrony_fallback_timesyncd" 0 "systemd-timesyncd 安装并启动成功" "" setup_chrony_fallback verify_chrony_fallback
run_case "all_failed_aborts" 1 "所有 NTP 服务均不可用" "已成功启动" setup_all_failed verify_all_failed
run_case "timedatectl_synced" 0 "NTPSynchronized=yes" "" setup_timedatectl_synced verify_timedatectl_synced

printf '\nAll setup_ntp behavioral test cases passed successfully!\n'
