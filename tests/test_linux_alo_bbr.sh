#!/usr/bin/env bash
#
# enable_bbr 回归测试（mock，不需要 root）：
# - 默认 sysctl 持久化落在 /etc/sysctl.d/90-bbr.conf（Debian 13 不再读取 /etc/sysctl.conf）
# - 成功路径幂等，且不批量改写现有网卡 qdisc（无 tc 调用）
# - 内核不支持时干净失败：不写 sysctl / modules-load，不打印成功
# - sysctl -p 失败时返回非零且不打印成功

set -Eeuo pipefail

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/shell/linux-alo.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# 用例 1：默认 sysctl 路径必须在 sysctl.d，且源码不得再批量 tc 改写。
echo "== default path & no bulk tc =="
grep -q 'BBR_SYSCTL_CONF:-/etc/sysctl.d/90-bbr.conf' "$script_path" \
    || fail "默认 BBR_SYSCTL_CONF 应为 /etc/sysctl.d/90-bbr.conf"
grep -q 'BBR_SYSCTL_CONF:-/etc/sysctl.conf' "$script_path" \
    && fail "不应再默认写 /etc/sysctl.conf"
# 提取 enable_bbr 函数体，确认没有全接口 tc 改写。
bbr_body="$(awk '/^enable_bbr\(\)/,/^}/' "$script_path")"
printf '%s\n' "$bbr_body" | grep -q 'tc qdisc replace' \
    && fail "enable_bbr 不得批量 tc qdisc replace 现有网卡"
printf 'PASS: default-sysctl-path-no-bulk-tc\n'

# 通用 mock 环境搭建。
setup_mocks() {
    local case_dir="$1"
    local mock_bin="$case_dir/bin"
    local state_dir="$case_dir/state"
    mkdir -p "$mock_bin" "$state_dir"
    touch "$state_dir/calls.log"
    printf '%s' "$mock_bin"
}

write_mock_modprobe() {
    local mock_bin="$1" state_dir="$2" sys_mod="$3"
    cat > "$mock_bin/modprobe" <<EOS
#!/usr/bin/env bash
echo "modprobe \$*" >> "$state_dir/calls.log"
if [ -f "$state_dir/fail_modprobe_\$1" ]; then exit 1; fi
if [ "\$1" = "tcp_bbr" ]; then mkdir -p "$sys_mod/tcp_bbr"; fi
if [ "\$1" = "sch_fq" ]; then mkdir -p "$sys_mod/sch_fq"; fi
exit 0
EOS
    chmod +x "$mock_bin/modprobe"
}

write_mock_modinfo() {
    local mock_bin="$1" state_dir="$2"
    cat > "$mock_bin/modinfo" <<EOS
#!/usr/bin/env bash
echo "modinfo \$*" >> "$state_dir/calls.log"
[ -f "$state_dir/modinfo_has_bbr" ] && exit 0 || exit 1
EOS
    chmod +x "$mock_bin/modinfo"
}

write_mock_lsmod() {
    local mock_bin="$1" state_dir="$2" sys_mod="$3"
    cat > "$mock_bin/lsmod" <<EOS
#!/usr/bin/env bash
echo "lsmod" >> "$state_dir/calls.log"
if [ -d "$sys_mod/tcp_bbr" ]; then echo "tcp_bbr 20480 0"; fi
exit 0
EOS
    chmod +x "$mock_bin/lsmod"
}

write_mock_sysctl() {
    local mock_bin="$1" state_dir="$2"
    cat > "$mock_bin/sysctl" <<EOS
#!/usr/bin/env bash
echo "sysctl \$*" >> "$state_dir/calls.log"
if [ "\${1:-}" = "-n" ]; then
  case "\$2" in
    net.ipv4.tcp_congestion_control) cat "$state_dir/cong";;
    net.core.default_qdisc) cat "$state_dir/qdisc";;
    net.ipv4.tcp_available_congestion_control) cat "$state_dir/avail";;
  esac
  exit 0
fi
if [ "\${1:-}" = "-p" ]; then
  [ -f "$state_dir/fail_sysctl_p" ] && exit 1
  echo bbr > "$state_dir/cong"
  echo fq > "$state_dir/qdisc"
  echo "cubic reno bbr" > "$state_dir/avail"
  exit 0
fi
if [ "\${1:-}" = "-w" ]; then
  kv="\$2"; k="\${kv%%=*}"; v="\${kv#*=}"
  [ "\$k" = "net.ipv4.tcp_congestion_control" ] && echo "\$v" > "$state_dir/cong"
  [ "\$k" = "net.core.default_qdisc" ] && echo "\$v" > "$state_dir/qdisc"
  exit 0
fi
exit 0
EOS
    chmod +x "$mock_bin/sysctl"
}

write_mock_tc_ip() {
    local mock_bin="$1" state_dir="$2"
    cat > "$mock_bin/tc" <<EOS
#!/usr/bin/env bash
echo "tc \$*" >> "$state_dir/calls.log"
exit 0
EOS
    chmod +x "$mock_bin/tc"
    cat > "$mock_bin/ip" <<EOS
#!/usr/bin/env bash
echo "ip \$*" >> "$state_dir/calls.log"
echo "1: lo: <LOOPBACK>"
echo "2: eth0: <BROADCAST>"
EOS
    chmod +x "$mock_bin/ip"
}

run_enable_bbr() {
    local mock_bin="$1" state_dir="$2" sysctl_conf="$3" modload="$4" sys_mod="$5" lib_base="$6"
    PATH="$mock_bin:/usr/bin:/bin" \
    BBR_SYSCTL_CONF="$sysctl_conf" \
    BBR_MODULES_LOAD_CONF="$modload" \
    BBR_SYS_MODULE_BASE="$sys_mod" \
    BBR_LIB_MODULES_BASE="$lib_base" \
    BBR_UNAME_R="6.1.0-test" \
    bash -c 'source "$1"; enable_bbr' bash "$script_path" 2>&1
}

# 用例 2：成功路径幂等 + 不调用 tc。
echo "== success idempotent, no tc =="
case_dir="$test_root/success"
mock_bin="$(setup_mocks "$case_dir")"
state_dir="$case_dir/state"
sys_mod="$case_dir/sysmod"
lib_base="$case_dir/libmod"
lib_ipv4="$lib_base/6.1.0-test/kernel/net/ipv4"
mkdir -p "$sys_mod" "$lib_ipv4"
touch "$lib_ipv4/tcp_bbr.ko" "$state_dir/modinfo_has_bbr"
echo "cubic reno" > "$state_dir/avail"
echo "cubic" > "$state_dir/cong"
echo "fq_codel" > "$state_dir/qdisc"
sysctl_conf="$case_dir/90-bbr.conf"
modload="$case_dir/bbr.conf"
write_mock_modprobe "$mock_bin" "$state_dir" "$sys_mod"
write_mock_modinfo "$mock_bin" "$state_dir"
write_mock_lsmod "$mock_bin" "$state_dir" "$sys_mod"
write_mock_sysctl "$mock_bin" "$state_dir"
write_mock_tc_ip "$mock_bin" "$state_dir"

set +e
out="$(run_enable_bbr "$mock_bin" "$state_dir" "$sysctl_conf" "$modload" "$sys_mod" "$lib_base")"
st=$?
set -e
[ "$st" -eq 0 ] || fail "成功路径应 exit 0，实际 $st：$out"
printf '%s\n' "$out" | grep -q "BBR 已成功开启" || fail "成功路径应打印成功：$out"
grep -qxF "tcp_bbr" "$modload" || fail "modules-load 缺少 tcp_bbr"
grep -qxF "sch_fq" "$modload" || fail "modules-load 缺少 sch_fq"
grep -qE '^net.ipv4.tcp_congestion_control=bbr$' "$sysctl_conf" || fail "sysctl 缺少 bbr"
grep -qE '^net.core.default_qdisc=fq$' "$sysctl_conf" || fail "sysctl 缺少 fq"
grep -qE '(^| )tc( |$)' "$state_dir/calls.log" && fail "成功路径不得调用 tc 改写现有网卡"
lines_before="$(wc -l < "$sysctl_conf")"
mlines_before="$(wc -l < "$modload")"
set +e
out2="$(run_enable_bbr "$mock_bin" "$state_dir" "$sysctl_conf" "$modload" "$sys_mod" "$lib_base")"
st2=$?
set -e
[ "$st2" -eq 0 ] || fail "重复执行应 exit 0"
[ "$(wc -l < "$sysctl_conf")" = "$lines_before" ] || fail "sysctl 重复执行不应追加"
[ "$(wc -l < "$modload")" = "$mlines_before" ] || fail "modules-load 重复执行不应追加"
printf 'PASS: success-idempotent-no-tc\n'

# 用例 3：内核不支持时干净失败，不写任何持久化文件。
echo "== unsupported kernel clean fail =="
case_dir="$test_root/unsupported"
mock_bin="$(setup_mocks "$case_dir")"
state_dir="$case_dir/state"
sys_mod="$case_dir/sysmod"
lib_base="$case_dir/libmod"
mkdir -p "$sys_mod" "$lib_base/6.1.0-test/kernel/net/ipv4"
echo "cubic reno" > "$state_dir/avail"
echo "cubic" > "$state_dir/cong"
echo "fq_codel" > "$state_dir/qdisc"
touch "$state_dir/fail_modprobe_tcp_bbr"
sysctl_conf="$case_dir/90-bbr.conf"
modload="$case_dir/bbr.conf"
write_mock_modprobe "$mock_bin" "$state_dir" "$sys_mod"
write_mock_modinfo "$mock_bin" "$state_dir"
write_mock_lsmod "$mock_bin" "$state_dir" "$sys_mod"
write_mock_sysctl "$mock_bin" "$state_dir"
write_mock_tc_ip "$mock_bin" "$state_dir"

set +e
out="$(run_enable_bbr "$mock_bin" "$state_dir" "$sysctl_conf" "$modload" "$sys_mod" "$lib_base")"
st=$?
set -e
[ "$st" -ne 0 ] || fail "不支持内核应返回非零"
printf '%s\n' "$out" | grep -q "BBR 已成功开启" && fail "失败路径不得打印成功"
[ ! -e "$sysctl_conf" ] || fail "失败路径不得写入 sysctl 文件"
[ ! -e "$modload" ] || fail "失败路径不得写入 modules-load 文件"
printf 'PASS: unsupported-clean-fail\n'

# 用例 4：sysctl -p 失败时返回非零且不报成功。
echo "== sysctl -p failure =="
case_dir="$test_root/sysctl-fail"
mock_bin="$(setup_mocks "$case_dir")"
state_dir="$case_dir/state"
sys_mod="$case_dir/sysmod"
lib_base="$case_dir/libmod"
lib_ipv4="$lib_base/6.1.0-test/kernel/net/ipv4"
mkdir -p "$sys_mod" "$lib_ipv4"
touch "$lib_ipv4/tcp_bbr.ko" "$state_dir/modinfo_has_bbr" "$state_dir/fail_sysctl_p"
echo "cubic reno" > "$state_dir/avail"
echo "cubic" > "$state_dir/cong"
echo "fq_codel" > "$state_dir/qdisc"
sysctl_conf="$case_dir/90-bbr.conf"
modload="$case_dir/bbr.conf"
write_mock_modprobe "$mock_bin" "$state_dir" "$sys_mod"
write_mock_modinfo "$mock_bin" "$state_dir"
write_mock_lsmod "$mock_bin" "$state_dir" "$sys_mod"
write_mock_sysctl "$mock_bin" "$state_dir"
write_mock_tc_ip "$mock_bin" "$state_dir"

set +e
out="$(run_enable_bbr "$mock_bin" "$state_dir" "$sysctl_conf" "$modload" "$sys_mod" "$lib_base")"
st=$?
set -e
[ "$st" -ne 0 ] || fail "sysctl -p 失败应返回非零"
printf '%s\n' "$out" | grep -q "BBR 已成功开启" && fail "sysctl 失败不得打印成功"
printf 'PASS: sysctl-p-fail\n'

printf '\nAll enable_bbr behavioral test cases passed successfully!\n'
