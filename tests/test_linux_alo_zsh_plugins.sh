#!/usr/bin/env bash
#
# install_zsh_plugins 回归测试（mock，不需要 root）：
# - 关键写操作必须显式 fail：main() 以 `install_zsh_plugins || true`
#   容错时，函数体内部不再受 `set -e` 保护（Bash 手册：-e 被忽略的
#   上下文中执行的 function，其内部命令同样不受 -e 影响）。
# - 写失败（touch/mv/追加重定向）时函数必须返回非零，且不得打印成功信息。
# - 显式失败时 `|| true` 必须让后续步骤继续执行。

set -Eeuo pipefail

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/shell/linux-alo.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# 用例 1：源码静态检查 —— 关键写操作必须有显式守卫，不得依赖隐式 set -e。
echo "== explicit write guards =="
grep -qF 'if ! touch "$zshrc_file"' "$script_path" \
    || fail "install_zsh_plugins 必须显式检查 touch \$zshrc_file"
grep -qF 'if ! tmp_zshrc=$(mktemp)' "$script_path" \
    || fail "install_zsh_plugins 必须显式检查 mktemp"
grep -qF 'if ! mv "$tmp_zshrc" "$zshrc_file"' "$script_path" \
    || fail "install_zsh_plugins 必须显式检查 mv 回写"
grep -q '^[[:space:]]*install_zsh_plugins || true' "$script_path" \
    || fail "main() 应以 'install_zsh_plugins || true' 容错调用"
printf 'PASS: explicit-write-guards\n'

# 以“set -e 被忽略”的上下文运行函数，模拟 main() 中 `|| true` 左侧的语义，
# 同时保留函数的真实退出码供断言。
run_plugins_no_errexit() {
    local zdotdir="$1" home="$2" mock_bin="${3:-}"
    local path="PATH=\"$mock_bin:/usr/bin:/bin\""
    [ -n "$mock_bin" ] || path='PATH="/usr/bin:/bin"'
    ZDOTDIR="$zdotdir" HOME="$home" bash -c "
        $path
        export PATH
        source \"\$1\"
        set +e
        install_zsh_plugins
        st=\$?
        exit \$st
    " bash "$script_path" 2>&1
}

# 用例 2：.zshrc 不可写（ZDOTDIR 指向普通文件，touch 报 ENOTDIR，root 下同样生效）。
# 即使在 -e 被忽略的上下文中，也必须返回非零且不打印“配置完成”。
echo "== unwritable zshrc fails loudly =="
case_dir="$test_root/unwritable"
mkdir -p "$case_dir/home"
touch "$case_dir/blocker"
set +e
out="$(run_plugins_no_errexit "$case_dir/blocker" "$case_dir/home")"
st=$?
set -e
[ "$st" -ne 0 ] || fail "不可写 .zshrc 应返回非零，实际 $st：$out"
printf '%s\n' "$out" | grep -q "zsh 插件配置完成" \
    && fail "写失败时不得打印成功信息：$out"
printf '%s\n' "$out" | grep -q "无法创建或访问" \
    || fail "写失败时应打印明确错误：$out"
printf 'PASS: unwritable-zshrc-fails-loudly\n'

# 用例 3：显式失败时 main 编排必须继续（warn-continue）。
echo "== warn-continue in main context =="
set +e
out="$(ZDOTDIR="$case_dir/blocker" HOME="$case_dir/home" bash -c '
    PATH="/usr/bin:/bin"
    export PATH
    source "$1"
    set -Eeuo pipefail
    install_zsh_plugins || true
    echo "CONTINUED-AFTER-PLUGINS"
' bash "$script_path" 2>&1)"
st=$?
set -e
[ "$st" -eq 0 ] || fail "|| true 容错后应 exit 0，实际 $st：$out"
printf '%s\n' "$out" | grep -q "CONTINUED-AFTER-PLUGINS" \
    || fail "容错后后续步骤必须继续执行：$out"
printf '%s\n' "$out" | grep -q "zsh 插件配置完成" \
    && fail "失败路径不得打印成功信息：$out"
printf 'PASS: warn-continue-in-main-context\n'

# 用例 4：清理旧 block 时的 mv 失败必须显式返回非零（mock mv 恒失败）。
echo "== mv failure fails loudly =="
case_dir="$test_root/mv-fail"
mkdir -p "$case_dir/home" "$case_dir/zdot" "$case_dir/bin"
{
    printf '# >>> linux-alo.sh managed zsh plugin sources >>>\n'
    printf 'source "/old/path.zsh"\n'
    printf '# <<< linux-alo.sh managed zsh plugin sources <<<\n'
} > "$case_dir/zdot/.zshrc"
cat > "$case_dir/bin/mv" <<'EOS'
#!/usr/bin/env bash
echo "mock-mv $*" >&2
exit 1
EOS
chmod +x "$case_dir/bin/mv"
set +e
out="$(run_plugins_no_errexit "$case_dir/zdot" "$case_dir/home" "$case_dir/bin")"
st=$?
set -e
[ "$st" -ne 0 ] || fail "mv 失败应返回非零，实际 $st：$out"
printf '%s\n' "$out" | grep -q "zsh 插件配置完成" \
    && fail "mv 失败时不得打印成功信息：$out"
printf 'PASS: mv-failure-fails-loudly\n'

# 用例 5：happy path —— 可写环境下成功，且重复执行可走 mv 回写分支。
if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
   [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    echo "== happy path & idempotent mv =="
    case_dir="$test_root/happy"
    mkdir -p "$case_dir/home" "$case_dir/zdot"
    for run in 1 2; do
        set +e
        out="$(run_plugins_no_errexit "$case_dir/zdot" "$case_dir/home")"
        st=$?
        set -e
        [ "$st" -eq 0 ] || fail "第 $run 次运行应 exit 0，实际 $st：$out"
        printf '%s\n' "$out" | grep -q "zsh 插件配置完成" \
            || fail "第 $run 次运行应打印成功：$out"
    done
    grep -qF '# >>> linux-alo.sh managed zsh plugin sources >>>' "$case_dir/zdot/.zshrc" \
        || fail "成功后 .zshrc 应包含 managed block"
    printf 'PASS: happy-path-idempotent-mv\n'
else
    echo "== happy path SKIPPED (系统 zsh 插件包缺失，仅 CI/本机有包时运行) =="
fi

printf '\nAll install_zsh_plugins behavioral test cases passed successfully!\n'
