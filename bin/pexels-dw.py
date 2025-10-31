#!/usr/bin/env python3
"""
Pexels 下载器（Python 版本）

使用方法：
  1) 运行本脚本
  2) 粘贴/输入包含下载链接的 JSON 或文本（含 https 链接即可）
  3) 结束输入：
     - macOS/Linux：按 Ctrl-D
     - Windows（PowerShell/CMD）：按 Ctrl-Z 然后回车

功能特性：
  - 从 STDIN 读取内容，智能提取所有 https:// 链接（解析 JSON 或正则扫描）
  - 下载到系统下载目录下的 videos_YYYYMMDD_HHMMSS 子目录
  - 优先调用 aria2c 并发下载与断点续传；若未安装则使用 Python 并发下载（含简易断点续传）
  - 下载完成后尝试系统通知（macOS 通知中心或 Linux notify-send）
"""

from __future__ import annotations

import concurrent.futures as _fut
import json
import os
import platform
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from shutil import which
from subprocess import CalledProcessError, run
from typing import Iterable, List, Optional, Set


URL_RE = re.compile(r"https://[^\s\"'<>]+", re.IGNORECASE)


def read_stdin_text() -> str:
  # 交互式终端：逐行读取，兼容多种结束方式
  # - Windows: 支持 Ctrl-Z（^Z）在任意位置出现（建议单独一行），随后回车
  # - *nix: Ctrl-D 触发 EOFError
  # - 仍保留可见的 EOF/END/. 作为备用方案
  if sys.stdin.isatty():
    lines: List[str] = []
    sentinels = {"EOF", "END", ".", "结束", "退出"}
    while True:
      try:
        line = input()
      except EOFError:
        # Ctrl-D（或 Windows 下 Ctrl-Z+回车 在行首）
        break
      # 处理 Windows 的 Ctrl-Z 字符（ASCII 26，显示为 ^Z）
      if "\x1a" in line:
        before, _sep, _after = line.partition("\x1a")
        if before:
          lines.append(before)
        break
      # 可见的备用结束标记
      if line.strip() in sentinels:
        break
      lines.append(line)
    return "\n".join(lines).strip()
  # 非交互（管道/重定向）保持一次性读取
  data = sys.stdin.read()
  return data.strip()


def extract_urls_from_json(obj) -> Set[str]:
  urls: Set[str] = set()

  def _walk(o):
    if isinstance(o, dict):
      for v in o.values():
        _walk(v)
    elif isinstance(o, list):
      for v in o:
        _walk(v)
    elif isinstance(o, str):
      for m in URL_RE.findall(o):
        if m.lower().startswith("https://"):
          urls.add(m)

  _walk(obj)
  return urls


def extract_urls(text: str) -> List[str]:
  # 优先尝试 JSON 解析，失败则回退到正则扫描
  urls: Set[str] = set()
  try:
    parsed = json.loads(text)
    urls |= extract_urls_from_json(parsed)
  except Exception:
    pass

  # 再从原始文本补充扫描一遍，兼容非 JSON 输入
  for m in URL_RE.findall(text):
    if m.lower().startswith("https://"):
      urls.add(m)

  # 去掉尾随标点或右括号等常见粘连符号
  cleaned = []
  for u in urls:
    # 去除常见尾随符号：., ); ] " '
    cleaned.append(u.rstrip(".,);]\"'"))
  # 去重并稳定排序
  return sorted(set(cleaned))


def get_downloads_dir() -> Path:
  system = platform.system().lower()
  home = Path.home()
  if system == "darwin" or system == "linux":
    return home / "Downloads"
  if system == "windows":
    userprofile = os.environ.get("USERPROFILE")
    if userprofile:
      return Path(userprofile) / "Downloads"
  return Path.cwd()


def notify(title: str, message: str) -> None:
  # macOS 通知
  if which("osascript"):
    try:
      run(["osascript", "-e", f'display notification "{message}" with title "{title}"'], check=True)
      return
    except CalledProcessError:
      pass
  # Linux 通知
  if which("notify-send"):
    try:
      run(["notify-send", title, message], check=True)
    except CalledProcessError:
      pass


@dataclass
class DownloadResult:
  url: str
  path: Path
  ok: bool
  error: Optional[str] = None


def filename_from_url(url: str) -> str:
  # 去掉查询串
  pure = url.split("?", 1)[0]
  name = os.path.basename(urllib.parse.urlparse(pure).path)
  if not name:
    name = f"file_{int(time.time() * 1000)}"
  return name


def http_download(url: str, outdir: Path, timeout: int = 30, retries: int = 3) -> DownloadResult:
  target = outdir / filename_from_url(url)
  attempt = 0
  headers = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
    "Accept": "*/*",
    "Connection": "keep-alive",
  }
  while attempt < retries:
    attempt += 1
    try:
      # 断点续传：若已存在，尝试 Range 续传
      resume_from = target.stat().st_size if target.exists() else 0
      req_headers = dict(headers)
      mode = "ab" if resume_from > 0 else "wb"
      if resume_from > 0:
        req_headers["Range"] = f"bytes={resume_from}-"

      req = urllib.request.Request(url, headers=req_headers, method="GET")
      with urllib.request.urlopen(req, timeout=timeout) as resp, open(target, mode) as f:
        # 对于非 206 响应且存在本地部分文件的情况，若返回 200，则重新下载
        if resume_from > 0 and getattr(resp, "status", None) == 200:
          # 服务器不支持断点，重新下
          f.close()
          target.unlink(missing_ok=True)
          resume_from = 0
          mode = "wb"
          req = urllib.request.Request(url, headers=headers, method="GET")
          with urllib.request.urlopen(req, timeout=timeout) as resp2, open(target, mode) as f2:
            _stream_copy(resp2, f2)
        else:
          _stream_copy(resp, f)
      return DownloadResult(url=url, path=target, ok=True)
    except Exception as e:
      last_err = str(e)
      time.sleep(min(2 ** attempt, 5))
  return DownloadResult(url=url, path=target, ok=False, error=last_err)


def _stream_copy(resp, out_file, chunk_size: int = 1024 * 256):
  while True:
    chunk = resp.read(chunk_size)
    if not chunk:
      break
    out_file.write(chunk)


def download_with_aria2(urls: List[str], outdir: Path) -> int:
  list_file = outdir / "urls.txt"
  list_file.write_text("\n".join(urls), encoding="utf-8")
  print("开始下载，请稍候…")
  proc = run(
    [
      "aria2c",
      "-x16",
      "-s16",
      "-c",
      "-k1M",
      "--allow-overwrite=true",
      "-d",
      str(outdir),
      "-i",
      str(list_file),
      "--console-log-level=notice",
    ]
  )
  return proc.returncode


def download_with_python(urls: List[str], outdir: Path, max_workers: int = 4) -> int:
  total = len(urls)
  print(f"未检测到 aria2c，使用 Python 并发下载（{max_workers} 线程，含断点续传）…")
  results: List[DownloadResult] = []
  idx = 0
  def task(u: str) -> DownloadResult:
    nonlocal idx
    i = None
    # 仅用于打印序号，不保证严格原子，但足够提示进度
    try:
      i = idx = idx + 1
    except Exception:
      i = 0
    name = filename_from_url(u)
    print(f"下载 [{i}/{total}]: {name}")
    res = http_download(u, outdir)
    if res.ok:
      print(f"✓ 完成: {res.path.name}")
    else:
      print(f"✗ 失败: {name} -> {res.error}")
    return res

  with _fut.ThreadPoolExecutor(max_workers=max_workers) as ex:
    for r in ex.map(task, urls):
      results.append(r)

  failures = [r for r in results if not r.ok]
  if failures:
    print(f"共有 {len(failures)} 个失败条目。")
    return 1
  return 0


def main() -> int:
  if sys.stdin.isatty():
    eof_hint = ("Ctrl-Z 然后回车" if os.name == "nt" else "Ctrl-D")
    print("提示：从 STDIN 读取输入。")
    if os.name == "nt":
      print("· Windows：按 Ctrl-Z 然后回车结束（最好在新的一行）。")
      print("  若看到 ^Z 出现在行内，也会被自动识别为结束标记。")
    else:
      print("· macOS/Linux：按 Ctrl-D 结束。")
    print("· 备用：也可在单独一行输入 EOF/END/. 结束\n")
  text = read_stdin_text()
  if not text:
    print("未读取到任何输入；请将包含 https 链接的 JSON/文本通过 STDIN 提供。")
    return 1

  urls = extract_urls(text)
  urls = [u.strip() for u in urls if u.strip().lower().startswith("https://")]
  # 去重并保持原有顺序（基于首次出现的顺序）
  seen = set()
  ordered: List[str] = []
  for u in urls:
    if u not in seen:
      seen.add(u)
      ordered.append(u)

  if not ordered:
    print("未在输入中发现可下载的 https 链接。")
    return 1

  downloads_dir = get_downloads_dir()
  downloads_dir.mkdir(parents=True, exist_ok=True)
  outdir = downloads_dir / time.strftime("videos_%Y%m%d_%H%M%S")
  outdir.mkdir(parents=True, exist_ok=True)

  print(f"共发现 {len(ordered)} 个链接，将下载到：{outdir}")

  # 优先 aria2c，否则 Python 下载
  if which("aria2c"):
    code = download_with_aria2(ordered, outdir)
  else:
    code = download_with_python(ordered, outdir)

  if code == 0:
    notify("Pexels 下载器", "视频下载完成！")
    print(f"全部任务完成。保存位置：{outdir}")
  else:
    print(f"部分或全部下载失败。保存位置：{outdir}")
  return code


if __name__ == "__main__":
  sys.exit(main())
