# Tools

自用脚本仓库，按语言和用途简单存放。

## 目录结构

```text
python/               Python CLI 小脚本
shell/                Shell 脚本
openwebui-function/   Open WebUI 相关脚本
```

## Python 基线

- 统一使用 `Python 3.12`
- 仓库根目录有 `.python-version`
- Python 依赖按用途分组，见 `pyproject.toml`

## 常用脚本

```bash
uv run python python/tools_use_test.py
uv run python python/pexels_dw.py
uv run python python/clean_ids.py
python openwebui-function/memory_re.py
bash shell/linux-alo.sh
bash shell/disable-password-login.sh
```

`tmp/` 保留给像 `python/clean_ids.py` 这类需要临时输入文件的脚本使用。
