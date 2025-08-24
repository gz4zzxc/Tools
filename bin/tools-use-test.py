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
        response = client.chat.completions.create(
            model=model_name,
            messages=[{"role": "user", "content": "你好，请简单介绍一下你自己"}],
            max_tokens=100
        )
        print("✅ 基本聊天功能正常")
        print(f"回复: {response.choices[0].message.content}")
        return True
    except Exception as e:
        print(f"❌ 基本聊天功能失败: {e}")
        return False


def test_tools_usage(client: OpenAI, model_name: str, tools: list[ChatCompletionToolParam]) -> bool:
    """测试工具使用功能"""
    print("\n=== 测试工具使用功能 ===")
    try:
        response = client.chat.completions.create(
            model=model_name,
            messages=[{"role": "user", "content": "请帮我查询北京的天气"}],
            tools=tools,
            tool_choice="auto",
            max_tokens=200
        )
        
        message = response.choices[0].message
        if message.tool_calls:
            print("✅ 模型支持工具调用！")
            for tool_call in message.tool_calls:
                print(f"工具名称: {tool_call.function.name}")
                print(f"参数: {tool_call.function.arguments}")
            return True
        else:
            print("⚠️  模型没有调用工具，但请求成功")
            print(f"回复: {message.content}")
            return False
            
    except Exception as e:
        print(f"❌ 工具使用测试失败: {e}")
        return False


def test_streaming_with_tools(client: OpenAI, model_name: str, tools: list[ChatCompletionToolParam]) -> bool:
    """测试流式响应中的工具使用"""
    print("\n=== 测试流式工具使用 ===")
    try:
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
        
        for chunk in response:
            if chunk.choices[0].delta.tool_calls:
                tool_calls_found = True
                print("🔧 检测到工具调用...")
            
            if chunk.choices[0].delta.content:
                content_parts.append(chunk.choices[0].delta.content)
                print(chunk.choices[0].delta.content, end="", flush=True)
        
        if tool_calls_found:
            print("\n✅ 流式响应中支持工具调用")
        else:
            print("\n⚠️  流式响应中未检测到工具调用")
        
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