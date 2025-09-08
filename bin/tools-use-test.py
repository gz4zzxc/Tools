#!/usr/bin/env python3
"""
OpenAI 格式模型工具使用测试脚本
支持交互式输入参数，测试模型是否支持工具调用
"""

import json
import sys
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
    print("=== OpenAI 格式模型工具使用测试 ===\n")
    
    base_url = get_user_input("请输入 base_url", "http://localhost:8000/v1")
    api_key = get_user_input("请输入 api_key", "sk-xxx")
    model_name = get_user_input("请输入模型名称", "deepseek-ai/DeepSeek-V3.1")
    
    return {
        "base_url": base_url,
        "api_key": api_key,
        "model_name": model_name
    }


def create_test_tools() -> list[ChatCompletionToolParam]:
    """创建测试用的工具定义"""
    return [
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "获取指定城市的天气信息",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "city": {
                            "type": "string",
                            "description": "城市名称"
                        },
                        "date": {
                            "type": "string",
                            "description": "日期，格式为 YYYY-MM-DD"
                        }
                    },
                    "required": ["city"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "calculate",
                "description": "执行数学计算",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "expression": {
                            "type": "string",
                            "description": "数学表达式，如 2+3*4"
                        }
                    },
                    "required": ["expression"]
                }
            }
        }
    ]


def test_basic_chat(client: OpenAI, model_name: str) -> bool:
    """测试基本的聊天功能"""
    print("\n=== 测试基本聊天功能 ===")
    try:
        start_ts = time.perf_counter()
        response = client.chat.completions.create(
            model=model_name,
            messages=[{"role": "user", "content": "你好，请简单介绍一下你自己"}],
            max_tokens=100
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
            if getattr(response, "usage", None) and getattr(response.usage, "completion_tokens", None) is not None:
                completion_tokens = int(response.usage.completion_tokens)
        except Exception:
            completion_tokens = None

        def _estimate_tokens(text: str) -> int:
            if not text:
                return 0
            cjk = re.findall(r"[\u4e00-\u9fff]", text)
            cjk_count = len(cjk)
            non_cjk_count = len(text) - cjk_count
            approx = cjk_count + math.ceil(non_cjk_count / 4)
            return max(approx, 1) if text.strip() else 0

        if completion_tokens is None:
            completion_tokens = _estimate_tokens(message.content or "")

        total_s = max(end_ts - start_ts, 1e-9)
        tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
        print(f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s")
        return True
    except Exception as e:
        print(f"❌ 基本聊天功能失败: {e}")
        return False


def test_tools_usage(client: OpenAI, model_name: str, tools: list[ChatCompletionToolParam]) -> bool:
    """测试工具使用功能"""
    print("\n=== 测试工具使用功能 ===")
    try:
        start_ts = time.perf_counter()
        response = client.chat.completions.create(
            model=model_name,
            messages=[{"role": "user", "content": "请帮我查询北京的天气"}],
            tools=tools,
            tool_choice="auto",
            max_tokens=200
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
                if getattr(response, "usage", None) and getattr(response.usage, "completion_tokens", None) is not None:
                    completion_tokens = int(response.usage.completion_tokens)
            except Exception:
                completion_tokens = None

            if completion_tokens is None:
                completion_tokens = 0

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s")
            return True
        else:
            print("⚠️  模型没有调用工具，但请求成功")
            print(f"回复: {message.content}")
            print(f"⏳ 首字延迟（TTFT）: {ttft_ms:.0f} ms")
            # 统计输出 tokens 与速率
            completion_tokens = None
            try:
                if getattr(response, "usage", None) and getattr(response.usage, "completion_tokens", None) is not None:
                    completion_tokens = int(response.usage.completion_tokens)
            except Exception:
                completion_tokens = None

            def _estimate_tokens(text: str) -> int:
                if not text:
                    return 0
                cjk = re.findall(r"[\u4e00-\u9fff]", text)
                cjk_count = len(cjk)
                non_cjk_count = len(text) - cjk_count
                approx = cjk_count + math.ceil(non_cjk_count / 4)
                return max(approx, 1) if text.strip() else 0

            if completion_tokens is None:
                completion_tokens = _estimate_tokens(message.content or "")

            total_s = max(end_ts - start_ts, 1e-9)
            tok_per_s = completion_tokens / total_s if total_s > 0 else float("inf")
            print(f"⏱️ 输出速率: {completion_tokens} tokens / {total_s:.2f}s ≈ {tok_per_s:.2f} tok/s")
            return False
            
    except Exception as e:
        print(f"❌ 工具使用测试失败: {e}")
        return False


def test_streaming_with_tools(client: OpenAI, model_name: str, tools: list[ChatCompletionToolParam]) -> bool:
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
                stream_options={"include_usage": True}
            )
        except TypeError:
            response = client.chat.completions.create(
                model=model_name,
                messages=[{"role": "user", "content": "请计算 15 * 23 的结果"}],
                tools=tools,
                tool_choice="auto",
                stream=True,
                max_tokens=200
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
            cjk = re.findall(r"[\u4e00-\u9fff]", final_text)
            cjk_count = len(cjk)
            non_cjk_count = len(final_text) - cjk_count
            final_usage_completion_tokens = (cjk_count + math.ceil(non_cjk_count / 4)) if final_text.strip() else 0

        # 输出速率基于首字到结束的时长，若无则用总时长
        start_for_speed = (first_content_ts or first_any_ts or start_ts)
        duration_s = max(end_ts - start_for_speed, 1e-9)
        tok_per_s = final_usage_completion_tokens / duration_s if duration_s > 0 else float("inf")
        print(f"⏱️ 输出速率: {final_usage_completion_tokens} tokens / {duration_s:.2f}s ≈ {tok_per_s:.2f} tok/s")

        return True
        
    except Exception as e:
        print(f"❌ 流式工具使用测试失败: {e}")
        return False


def main():
    """主函数"""
    try:
        # 获取用户输入
        params = get_model_parameters()
        
        # 创建 OpenAI 客户端
        print(f"\n正在连接到: {params['base_url']}")
        client = OpenAI(
            base_url=params['base_url'],
            api_key=params['api_key']
        )
        
        # 创建测试工具
        tools = create_test_tools()
        
        # 测试基本功能
        basic_success = test_basic_chat(client, params['model_name'])
        
        # 测试工具使用
        tools_success = test_tools_usage(client, params['model_name'], tools)
        
        # 测试流式工具使用
        streaming_success = test_streaming_with_tools(client, params['model_name'], tools)
        
        # 总结测试结果
        print("\n" + "="*50)
        print("测试结果总结:")
        print(f"基本聊天功能: {'✅ 通过' if basic_success else '❌ 失败'}")
        print(f"工具使用功能: {'✅ 通过' if tools_success else '❌ 失败'}")
        print(f"流式工具使用: {'✅ 通过' if streaming_success else '❌ 失败'}")
        
        if tools_success:
            print("\n🎉 该模型支持工具使用！")
        else:
            print("\n⚠️  该模型可能不支持工具使用")
            
    except KeyboardInterrupt:
        print("\n\n用户中断操作")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ 发生错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()