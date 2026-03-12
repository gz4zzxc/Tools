#!/usr/bin/env python3
"""
OpenAI/Anthropic 格式模型功能测试脚本
支持交互式输入参数，测试模型是否支持：
- 基本聊天功能
- 工具调用功能
- 流式响应
- 图片输入支持
"""

import base64
import json
import mimetypes
import sys
import urllib.error
from urllib.request import Request, urlopen
from typing import Dict, Any, Optional
from openai import OpenAI
from openai.types.chat import ChatCompletionToolParam
import time
import math
import re


def get_user_input(prompt: str, default: str = "") -> str:
    """获取用户输入，支持默认值"""
    if default:
        user_input = input(f"{prompt} (默认: {default}): ").strip()
        return user_input if user_input else default
    else:
        return input(f"{prompt}: ").strip()


def get_model_parameters() -> Dict[str, str]:
    """交互式获取模型参数"""
    print("=== OpenAI/Anthropic 格式模型工具使用测试 ===\n")

    print("请选择 API 格式:")
    print("  1) openai")
    print("  2) anthropic")
    api_choice = get_user_input("请输入选项", "1").strip().lower()

    if api_choice in {"1", "openai"}:
        api_format = "openai"
    elif api_choice in {"2", "anthropic"}:
        api_format = "anthropic"
    else:
        print(f"⚠️  不支持的选项: {api_choice}，将使用 1) openai")
        api_format = "openai"

    default_base_url = (
        "http://localhost:8000/v1"
        if api_format == "openai"
        else "http://localhost:8000"
    )
    base_url = get_user_input("请输入 base_url", default_base_url)
    api_key = get_user_input("请输入 api_key", "sk-xxx")
    model_name = get_user_input("请输入模型名称", "deepseek-ai/DeepSeek-V3.1")

    params = {
        "api_format": api_format,
        "base_url": base_url,
        "api_key": api_key,
        "model_name": model_name,
    }
    if api_format == "anthropic":
        params["anthropic_version"] = "2023-06-01"
    return params


def get_test_image_url() -> str:
    """获取测试图片的 URL"""
    # 使用一个公开的测试图片 URL（若下载失败会自动回退到内置图片）
    return "https://picsum.photos/512/320"


def get_builtin_test_image_base64() -> tuple[str, str]:
    """返回内置测试图片（1x1 PNG）的 base64 数据"""
    return (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+S84AAAAASUVORK5CYII=",
        "image/png",
    )


def estimate_tokens(text: str) -> int:
    """估算文本 token 数"""
    if not text:
        return 0
    cjk = re.findall(r"[\u4e00-\u9fff]", text)
    cjk_count = len(cjk)
    non_cjk_count = len(text) - cjk_count
    approx = cjk_count + math.ceil(non_cjk_count / 4)
    return max(approx, 1) if text.strip() else 0


def get_tool_definitions() -> list[Dict[str, Any]]:
    """返回统一工具定义"""
    return [
        {
            "name": "get_weather",
            "description": "获取指定城市的天气信息",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {"type": "string", "description": "城市名称"},
                    "date": {
                        "type": "string",
                        "description": "日期，格式为 YYYY-MM-DD",
                    },
                },
                "required": ["city"],
            },
        },
        {
            "name": "calculate",
            "description": "执行数学计算",
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": {
                        "type": "string",
                        "description": "数学表达式，如 2+3*4",
                    }
                },
                "required": ["expression"],
            },
        },
    ]


def create_test_tools_openai() -> list[ChatCompletionToolParam]:
    """创建 OpenAI 格式工具定义"""
    tools: list[ChatCompletionToolParam] = []
    for tool in get_tool_definitions():
        tools.append(
            {
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool["description"],
                    "parameters": tool["parameters"],
                },
            }
        )
    return tools


def create_test_tools_anthropic() -> list[Dict[str, Any]]:
    """创建 Anthropic 格式工具定义"""
    tools = []
    for tool in get_tool_definitions():
        tools.append(
            {
                "name": tool["name"],
                "description": tool["description"],
                "input_schema": tool["parameters"],
            }
        )
    return tools


def normalize_anthropic_messages_url(base_url: str) -> str:
    """将 base_url 规范化为 Anthropic messages 接口 URL"""
    cleaned = base_url.rstrip("/")
    if cleaned.endswith("/v1/messages"):
        return cleaned
    if cleaned.endswith("/v1"):
        return f"{cleaned}/messages"
    return f"{cleaned}/v1/messages"


def create_anthropic_headers(
    api_key: str, anthropic_version: str, stream: bool = False
) -> Dict[str, str]:
    """创建 Anthropic 请求头"""
    headers = {
        "content-type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": anthropic_version,
    }
    if stream:
        headers["accept"] = "text/event-stream"
    return headers


def anthropic_messages_create(
    params: Dict[str, str], payload: Dict[str, Any]
) -> Dict[str, Any]:
    """调用 Anthropic messages 接口（非流式）"""
    url = normalize_anthropic_messages_url(params["base_url"])
    req = Request(
        url=url,
        data=json.dumps(payload).encode("utf-8"),
        headers=create_anthropic_headers(
            params["api_key"], params["anthropic_version"]
        ),
        method="POST",
    )
    try:
        with urlopen(req, timeout=180) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {error_body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"网络错误: {e}") from e


def anthropic_stream_events(params: Dict[str, str], payload: Dict[str, Any]):
    """调用 Anthropic messages 接口（流式），按 SSE 事件产出 JSON"""
    stream_payload = dict(payload)
    stream_payload["stream"] = True
    url = normalize_anthropic_messages_url(params["base_url"])
    req = Request(
        url=url,
        data=json.dumps(stream_payload).encode("utf-8"),
        headers=create_anthropic_headers(
            params["api_key"], params["anthropic_version"], stream=True
        ),
        method="POST",
    )
    try:
        with urlopen(req, timeout=300) as resp:
            data_lines: list[str] = []
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="ignore").strip()
                if not line:
                    if not data_lines:
                        continue
                    raw_data = "\n".join(data_lines).strip()
                    data_lines = []
                    if raw_data == "[DONE]":
                        break
                    try:
                        event = json.loads(raw_data)
                    except json.JSONDecodeError:
                        continue
                    yield event
                    continue
                if line.startswith("data:"):
                    data_lines.append(line[len("data:") :].strip())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {error_body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"网络错误: {e}") from e


def extract_anthropic_text(content_blocks: list[Dict[str, Any]]) -> str:
    """从 Anthropic content 数组提取文本"""
    texts = []
    for block in content_blocks:
        if block.get("type") == "text" and block.get("text"):
            texts.append(block["text"])
    return "".join(texts)


def get_anthropic_output_tokens(response: Dict[str, Any]) -> Optional[int]:
    """获取 Anthropic 返回的 output_tokens"""
    usage = response.get("usage") or {}
    output_tokens = usage.get("output_tokens")
    if output_tokens is None:
        return None
    try:
        return int(output_tokens)
    except Exception:
        return None


def normalize_anthropic_tool_calls(
    content_blocks: list[Dict[str, Any]],
) -> list[Dict[str, Any]]:
    """规范化工具调用，兼容部分网关把 name/input 拆成多个 block 的情况"""
    normalized: list[Dict[str, Any]] = []
    for block in content_blocks:
        if block.get("type") != "tool_use":
            continue

        name = (block.get("name") or "").strip()
        input_payload = block.get("input") or {}
        if not isinstance(input_payload, dict):
            input_payload = {"raw_arguments": str(input_payload)}

        if name:
            normalized.append({"name": name, "input": input_payload})
            continue

        if not normalized:
            normalized.append({"name": "", "input": input_payload})
            continue

        prev_input = normalized[-1].get("input")
        if (
            isinstance(prev_input, dict)
            and prev_input.get("raw_arguments", "") == ""
            and len(prev_input) == 1
        ):
            normalized[-1]["input"] = input_payload
        elif isinstance(prev_input, dict):
            prev_input.update(input_payload)
        else:
            normalized[-1]["input"] = input_payload

    return normalized


def anthropic_messages_create_with_tool_choice_fallback(
    params: Dict[str, str], payload: Dict[str, Any]
) -> Dict[str, Any]:
    """带 tool_choice 兼容降级的 Anthropic 非流式请求"""
    try:
        return anthropic_messages_create(params, payload)
    except RuntimeError as e:
        err = str(e).lower()
        if "tool_choice" not in err or "tool_choice" not in payload:
            raise
        fallback_payload = dict(payload)
        fallback_payload.pop("tool_choice", None)
        print("⚠️  服务端不支持 tool_choice，已自动降级重试")
        return anthropic_messages_create(params, fallback_payload)


def anthropic_stream_events_with_tool_choice_fallback(
    params: Dict[str, str], payload: Dict[str, Any]
):
    """带 tool_choice 兼容降级的 Anthropic 流式请求"""
    try:
        yield from anthropic_stream_events(params, payload)
    except RuntimeError as e:
        err = str(e).lower()
        if "tool_choice" not in err or "tool_choice" not in payload:
            raise
        fallback_payload = dict(payload)
        fallback_payload.pop("tool_choice", None)
        print("⚠️  服务端不支持 tool_choice，已自动降级重试")
        yield from anthropic_stream_events(params, fallback_payload)


def load_image_as_base64(image_url: str) -> tuple[str, str]:
    """下载图片并转为 base64，返回 (base64_data, media_type)"""
    req = Request(image_url, headers={"User-Agent": "tools-use-test/1.0"})
    try:
        with urlopen(req, timeout=120) as resp:
            image_bytes = resp.read()
            media_type = resp.headers.get_content_type()
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"下载图片失败，HTTP {e.code}: {error_body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"下载图片失败: {e}") from e

    if not media_type or media_type == "application/octet-stream":
        guessed_media_type, _ = mimetypes.guess_type(image_url)
        media_type = guessed_media_type or "image/jpeg"

    return base64.b64encode(image_bytes).decode("utf-8"), media_type


def test_basic_chat(client: OpenAI, model_name: str) -> bool:
    """测试基本的聊天功能"""
    print("\n=== 测试基本聊天功能 ===")
    try:
        start_ts = time.perf_counter()
        response = client.chat.completions.create(
            model=model_name,
            messages=[{"role": "user", "content": "你好，请简单介绍一下你自己"}],
            max_tokens=100,
        )
        end_ts = time.perf_counter()
        ttft_ms = max((end_ts - start_ts) * 1000.0, 0.0)
        print("✅ 基本聊天功能正常")
        message = response.choices[0].message
        print(f"回复: {message.content}")
        print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")

        # 统计输出 tokens 与速率
        completion_tokens = None
        try:
            if (
                getattr(response, "usage", None)
                and getattr(response.usage, "completion_tokens", None) is not None
            ):
                completion_tokens = int(response.usage.completion_tokens)
        except Exception:
            completion_tokens = None

        if completion_tokens is None:
            completion_tokens = estimate_tokens(message.content or "")

        total_s = max(end_ts - start_ts, 1e-9)
        tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
        print(
            f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
        )
        return True
    except Exception as e:
        print(f"❌ 基本聊天功能失败: {e}")
        return False


def test_tools_usage(
    client: OpenAI, model_name: str, tools: list[ChatCompletionToolParam]
) -> bool:
    """测试工具使用功能"""
    print("\n=== 测试工具使用功能 ===")
    try:
        start_ts = time.perf_counter()
        response = client.chat.completions.create(
            model=model_name,
            messages=[{"role": "user", "content": "请帮我查询北京的天气"}],
            tools=tools,
            tool_choice="auto",
            max_tokens=200,
        )
        end_ts = time.perf_counter()
        ttft_ms = max((end_ts - start_ts) * 1000.0, 0.0)

        message = response.choices[0].message
        if message.tool_calls:
            print("✅ 模型支持工具调用！")
            for tool_call in message.tool_calls:
                print(f"工具名称: {tool_call.function.name}")
                print(f"参数: {tool_call.function.arguments}")
            print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
            # 统计输出 tokens 与速率（以 usage 为准，若无则估算为 0）
            completion_tokens = None
            try:
                if (
                    getattr(response, "usage", None)
                    and getattr(response.usage, "completion_tokens", None) is not None
                ):
                    completion_tokens = int(response.usage.completion_tokens)
            except Exception:
                completion_tokens = None

            if completion_tokens is None:
                completion_tokens = 0

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(
                f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
            )
            return True
        else:
            print("⚠️  模型没有调用工具，但请求成功")
            print(f"回复: {message.content}")
            print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
            # 统计输出 tokens 与速率
            completion_tokens = None
            try:
                if (
                    getattr(response, "usage", None)
                    and getattr(response.usage, "completion_tokens", None) is not None
                ):
                    completion_tokens = int(response.usage.completion_tokens)
            except Exception:
                completion_tokens = None

            if completion_tokens is None:
                completion_tokens = estimate_tokens(message.content or "")

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(
                f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
            )
            return False

    except Exception as e:
        print(f"❌ 工具使用测试失败: {e}")
        return False


def test_streaming_with_tools(
    client: OpenAI, model_name: str, tools: list[ChatCompletionToolParam]
) -> bool:
    """测试流式响应中的工具使用"""
    print("\n=== 测试流式工具使用 ===")
    try:
        start_ts = time.perf_counter()
        try:
            response = client.chat.completions.create(
                model=model_name,
                messages=[{"role": "user", "content": "请计算 15 * 23 的结果"}],
                tools=tools,
                tool_choice="auto",
                stream=True,
                max_tokens=200,
                stream_options={"include_usage": True},
            )
        except TypeError:
            response = client.chat.completions.create(
                model=model_name,
                messages=[{"role": "user", "content": "请计算 15 * 23 的结果"}],
                tools=tools,
                tool_choice="auto",
                stream=True,
                max_tokens=200,
            )

        print("流式响应:")
        tool_calls_found = False
        content_parts = []
        first_content_ts = None
        first_any_ts = None
        final_usage_completion_tokens = None

        for chunk in response:
            if chunk.choices[0].delta.tool_calls:
                tool_calls_found = True
                print("🔧 检测到工具调用...")
                if first_any_ts is None:
                    first_any_ts = time.perf_counter()

            if chunk.choices[0].delta.content:
                content_parts.append(chunk.choices[0].delta.content)
                print(chunk.choices[0].delta.content, end="", flush=True)
                now_ts = time.perf_counter()
                if first_content_ts is None:
                    first_content_ts = now_ts
                if first_any_ts is None:
                    first_any_ts = now_ts

            # 尝试在流末尾获取 usage（需服务端支持 include_usage）
            try:
                usage = getattr(chunk, "usage", None)
                if usage and getattr(usage, "completion_tokens", None) is not None:
                    final_usage_completion_tokens = int(usage.completion_tokens)
            except Exception:
                pass

        end_ts = time.perf_counter()

        if tool_calls_found:
            print("\n✅ 流式响应中支持工具调用")
        else:
            print("\n⚠️  流式响应中未检测到工具调用")

        # 统计 TTFT 与输出速率
        ttft_ref = first_content_ts or first_any_ts
        if ttft_ref is not None:
            ttft_ms = max((ttft_ref - start_ts) * 1000.0, 0.0)
            print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
        else:
            print("⏳ 首字延迟（TTFT）: 未检测到首个增量")

        if final_usage_completion_tokens is None:
            final_text = "".join(content_parts)
            # 估算 tokens（无 usage 时）
            final_usage_completion_tokens = estimate_tokens(final_text)

        # 输出速率基于首字到结束的时长，若无则用总时长
        start_for_speed = first_content_ts or first_any_ts or start_ts
        duration_s = max(end_ts - start_for_speed, 1e-9)
        tok_per_s = (
            final_usage_completion_tokens / duration_s
            if duration_s > 0
            else float("inf")
        )
        print(
            f"⏱️ 输出速率: {final_usage_completion_tokens} tokens / {duration_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
        )

        return tool_calls_found

    except Exception as e:
        print(f"❌ 流式工具使用测试失败: {e}")
        return False


def test_image_support(client: OpenAI, model_name: str) -> bool:
    """测试模型是否支持图片输入"""
    print("\n=== 测试图片支持功能 ===")
    try:
        # 获取测试图片 URL
        test_image_url = get_test_image_url()

        # 构建包含图片的消息
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "请描述一下这张图片的内容"},
                    {"type": "image_url", "image_url": {"url": test_image_url}},
                ],
            }
        ]

        start_ts = time.perf_counter()
        response = client.chat.completions.create(
            model=model_name, messages=messages, max_tokens=200
        )
        end_ts = time.perf_counter()

        message = response.choices[0].message
        if message.content:
            print("✅ 模型支持图片输入！")
            print(f"图片描述: {message.content}")

            # 统计输出 tokens 与速率
            completion_tokens = None
            try:
                if (
                    getattr(response, "usage", None)
                    and getattr(response.usage, "completion_tokens", None) is not None
                ):
                    completion_tokens = int(response.usage.completion_tokens)
            except Exception:
                completion_tokens = None

            if completion_tokens is None:
                completion_tokens = estimate_tokens(message.content or "")

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(
                f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
            )
            return True
        else:
            print("⚠️  模型接受了图片输入但没有返回内容")
            return False

    except Exception as e:
        error_msg = str(e).lower()
        if "vision" in error_msg or "image" in error_msg or "multimodal" in error_msg:
            print("❌ 模型不支持图片输入")
            print(f"错误信息: {e}")
        else:
            print(f"❌ 图片支持测试失败: {e}")
        return False


def test_basic_chat_anthropic(params: Dict[str, str]) -> bool:
    """测试 Anthropic 格式的基本聊天功能"""
    print("\n=== 测试基本聊天功能（Anthropic）===")
    try:
        start_ts = time.perf_counter()
        response = anthropic_messages_create(
            params,
            {
                "model": params["model_name"],
                "messages": [{"role": "user", "content": "你好，请简单介绍一下你自己"}],
                "max_tokens": 100,
            },
        )
        end_ts = time.perf_counter()
        ttft_ms = max((end_ts - start_ts) * 1000.0, 0.0)

        content_blocks = response.get("content") or []
        message_text = extract_anthropic_text(content_blocks)
        print("✅ 基本聊天功能正常")
        print(f"回复: {message_text or '[空回复]'}")
        print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")

        completion_tokens = get_anthropic_output_tokens(response)
        if completion_tokens is None:
            completion_tokens = estimate_tokens(message_text)

        total_s = max(end_ts - start_ts, 1e-9)
        tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
        print(
            f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
        )
        return True
    except Exception as e:
        print(f"❌ 基本聊天功能失败: {e}")
        return False


def test_tools_usage_anthropic(
    params: Dict[str, str], tools: list[Dict[str, Any]]
) -> bool:
    """测试 Anthropic 格式的工具使用功能"""
    print("\n=== 测试工具使用功能（Anthropic）===")
    try:
        start_ts = time.perf_counter()
        response = anthropic_messages_create_with_tool_choice_fallback(
            params,
            {
                "model": params["model_name"],
                "messages": [{"role": "user", "content": "请帮我查询北京的天气"}],
                "tools": tools,
                "tool_choice": {"type": "auto"},
                "max_tokens": 200,
            },
        )
        end_ts = time.perf_counter()
        ttft_ms = max((end_ts - start_ts) * 1000.0, 0.0)

        content_blocks = response.get("content") or []
        tool_calls = normalize_anthropic_tool_calls(content_blocks)
        message_text = extract_anthropic_text(content_blocks)

        if tool_calls:
            print("✅ 模型支持工具调用！")
            for tool_call in tool_calls:
                print(f"工具名称: {tool_call.get('name', '')}")
                print(
                    f"参数: {json.dumps(tool_call.get('input', {}), ensure_ascii=False)}"
                )
            print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
            completion_tokens = get_anthropic_output_tokens(response)
            if completion_tokens is None:
                completion_tokens = 0

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(
                f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
            )
            return True

        print("⚠️  模型没有调用工具，但请求成功")
        print(f"回复: {message_text or '[空回复]'}")
        print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
        completion_tokens = get_anthropic_output_tokens(response)
        if completion_tokens is None:
            completion_tokens = estimate_tokens(message_text)

        total_s = max(end_ts - start_ts, 1e-9)
        tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
        print(
            f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
        )
        return False

    except Exception as e:
        print(f"❌ 工具使用测试失败: {e}")
        return False


def test_streaming_with_tools_anthropic(
    params: Dict[str, str], tools: list[Dict[str, Any]]
) -> bool:
    """测试 Anthropic 格式流式响应中的工具使用"""
    print("\n=== 测试流式工具使用（Anthropic）===")
    try:
        start_ts = time.perf_counter()
        payload = {
            "model": params["model_name"],
            "messages": [{"role": "user", "content": "请计算 15 * 23 的结果"}],
            "tools": tools,
            "tool_choice": {"type": "auto"},
            "max_tokens": 200,
        }

        print("流式响应:")
        tool_calls_found = False
        content_parts: list[str] = []
        first_content_ts = None
        first_any_ts = None
        final_usage_completion_tokens = None

        for event in anthropic_stream_events_with_tool_choice_fallback(params, payload):
            event_type = event.get("type")

            # 记录 usage（Anthropic 通常在 message_delta 事件内返回）
            usage = event.get("usage") or {}
            output_tokens = usage.get("output_tokens")
            if output_tokens is not None:
                try:
                    final_usage_completion_tokens = int(output_tokens)
                except Exception:
                    pass

            if event_type == "content_block_start":
                block = event.get("content_block") or {}
                block_type = block.get("type")
                if block_type == "tool_use":
                    tool_calls_found = True
                    print("🔧 检测到工具调用...")
                    if first_any_ts is None:
                        first_any_ts = time.perf_counter()
                elif block_type == "text":
                    text = block.get("text", "")
                    if text:
                        content_parts.append(text)
                        print(text, end="", flush=True)
                        now_ts = time.perf_counter()
                        if first_content_ts is None:
                            first_content_ts = now_ts
                        if first_any_ts is None:
                            first_any_ts = now_ts
                continue

            if event_type == "content_block_delta":
                delta = event.get("delta") or {}
                delta_type = delta.get("type")
                if delta_type == "text_delta":
                    text = delta.get("text", "")
                    if text:
                        content_parts.append(text)
                        print(text, end="", flush=True)
                        now_ts = time.perf_counter()
                        if first_content_ts is None:
                            first_content_ts = now_ts
                        if first_any_ts is None:
                            first_any_ts = now_ts
                elif delta_type == "input_json_delta":
                    tool_calls_found = True
                    if first_any_ts is None:
                        first_any_ts = time.perf_counter()

        end_ts = time.perf_counter()

        if tool_calls_found:
            print("\n✅ 流式响应中支持工具调用")
        else:
            print("\n⚠️  流式响应中未检测到工具调用")

        ttft_ref = first_content_ts or first_any_ts
        if ttft_ref is not None:
            ttft_ms = max((ttft_ref - start_ts) * 1000.0, 0.0)
            print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
        else:
            print("⏳ 首字延迟（TTFT）: 未检测到首个增量")

        if final_usage_completion_tokens is None:
            final_usage_completion_tokens = estimate_tokens("".join(content_parts))

        start_for_speed = first_content_ts or first_any_ts or start_ts
        duration_s = max(end_ts - start_for_speed, 1e-9)
        tok_per_s = (
            final_usage_completion_tokens / duration_s
            if duration_s > 0
            else float("inf")
        )
        print(
            f"⏱️ 输出速率: {final_usage_completion_tokens} tokens / {duration_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
        )

        return tool_calls_found
    except Exception as e:
        print(f"❌ 流式工具使用测试失败: {e}")
        return False


def test_image_support_anthropic(params: Dict[str, str]) -> bool:
    """测试 Anthropic 格式模型是否支持图片输入"""
    print("\n=== 测试图片支持功能（Anthropic）===")
    try:
        test_image_url = get_test_image_url()
        try:
            image_b64, media_type = load_image_as_base64(test_image_url)
        except Exception as download_error:
            print(f"⚠️  测试图片下载失败，将使用内置图片继续测试: {download_error}")
            image_b64, media_type = get_builtin_test_image_base64()

        payload = {
            "model": params["model_name"],
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "请描述一下这张图片的内容"},
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": image_b64,
                            },
                        },
                    ],
                }
            ],
            "max_tokens": 200,
        }

        start_ts = time.perf_counter()
        response = anthropic_messages_create(params, payload)
        end_ts = time.perf_counter()

        content_blocks = response.get("content") or []
        message_text = extract_anthropic_text(content_blocks)
        if message_text:
            print("✅ 模型支持图片输入！")
            print(f"图片描述: {message_text}")
            completion_tokens = get_anthropic_output_tokens(response)
            if completion_tokens is None:
                completion_tokens = estimate_tokens(message_text)

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(
                f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s"
            )
            return True

        print("⚠️  模型接受了图片输入但没有返回内容")
        return False

    except Exception as e:
        if str(e).startswith("下载图片失败"):
            print("❌ 图片测试失败（测试图片下载失败，不代表模型不支持图片）")
            print(f"错误信息: {e}")
            return False
        error_msg = str(e).lower()
        if "http 401" in error_msg and "openai_api_key" in error_msg:
            print("❌ 图片测试失败（鉴权失败，不代表模型不支持图片）")
            print(
                "错误信息: 网关返回「Invalid API key / OPENAI_API_KEY」，请检查传入的 ModelScope Token 是否正确且有该模型权限。"
            )
            print(f"原始错误: {e}")
            return False
        if "vision" in error_msg or "image" in error_msg or "multimodal" in error_msg:
            print("❌ 模型不支持图片输入")
            print(f"错误信息: {e}")
        else:
            print(f"❌ 图片支持测试失败: {e}")
        return False


def main():
    """主函数"""
    try:
        # 获取用户输入
        params = get_model_parameters()

        api_format = params["api_format"]
        print(f"\n正在连接到: {params['base_url']} (格式: {api_format})")

        if api_format == "anthropic":
            tools = create_test_tools_anthropic()
            basic_success = test_basic_chat_anthropic(params)
            tools_success = test_tools_usage_anthropic(params, tools)
            streaming_success = test_streaming_with_tools_anthropic(params, tools)
            image_success = test_image_support_anthropic(params)
        else:
            client = OpenAI(base_url=params["base_url"], api_key=params["api_key"])
            tools = create_test_tools_openai()
            basic_success = test_basic_chat(client, params["model_name"])
            tools_success = test_tools_usage(client, params["model_name"], tools)
            streaming_success = test_streaming_with_tools(
                client, params["model_name"], tools
            )
            image_success = test_image_support(client, params["model_name"])

        # 总结测试结果
        print("\n" + "=" * 50)
        print("测试结果总结:")
        print(f"基本聊天功能: {'✅ 通过' if basic_success else '❌ 失败'}")
        print(f"工具使用功能: {'✅ 通过' if tools_success else '❌ 失败'}")
        print(f"流式工具使用: {'✅ 通过' if streaming_success else '❌ 失败'}")
        print(f"图片支持功能: {'✅ 通过' if image_success else '❌ 失败'}")

        # 功能支持总结
        print("\n功能支持总结:")
        if tools_success:
            print("🎉 该模型支持工具使用！")
        else:
            print("⚠️  该模型可能不支持工具使用")

        if image_success:
            print("🖼️  该模型支持图片输入！")
        else:
            print("⚠️  该模型可能不支持图片输入")

    except KeyboardInterrupt:
        print("\n\n用户中断操作")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ 发生错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
