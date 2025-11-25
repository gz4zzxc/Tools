"""
title: 超级记忆助手 (Pro)
description: 自动提取对话事实、去重、并添加精确时间戳。优化了配置界面和类型安全。
author: 南风 (二改Bryce) & Gemini
version: 7.2
required_open_webui_version: >= 0.5.0
"""

import json
import asyncio
import time
import datetime
import re
from typing import Optional, Callable, Awaitable, Any, List, Dict, Tuple

import pytz
from pydantic import BaseModel, Field
from fastapi.requests import Request

# 核心引用：保持使用 Router，这是目前复用系统 Embedding 最稳定的方式
from open_webui.models.users import Users
from open_webui.routers.memories import (
    add_memory,
    AddMemoryForm,
    query_memory,
    QueryMemoryForm,
    delete_memory_by_id,
)
from open_webui.main import app as webui_app

# ==================== 提示词常量 ====================
FACT_EXTRACTION_PROMPT = """你正在帮助维护用户的“记忆”。你的任务是判断用户的【最新一条】消息中，有哪些细节值得作为“记忆”被长期保存。\n【核心指令】\n1. 只分析用户最新一条消息。\n2. 忽略临时信息。\n3. 返回JSON字符串数组，如 ["用户喜欢吃苹果", "用户是一名程序员"]。"""

class Filter:
    # 类变量：用于简单的跨请求状态跟踪
    _user_memory_counters: Dict[str, int] = {}
    _summarization_running: set = set()

    class Valves(BaseModel):
        """
        配置项类 - 使用 title 属性优化前端显示
        """
        enabled: bool = Field(
            default=True, 
            description="开启或关闭插件功能",
            json_schema_extra={"title": "🔌 启用插件"}
        )
        api_url: str = Field(
            default="https://api.openai.com/v1/chat/completions", 
            description="用于提取记忆的 LLM API 地址",
            json_schema_extra={"title": "🤖 API 地址"}
        )
        api_key: str = Field(
            default="", 
            description="用于提取记忆的 API Key",
            json_schema_extra={"title": "🔑 API Key"}
        )
        model: str = Field(
            default="gpt-4o-mini", 
            description="建议使用快速且智能的模型",
            json_schema_extra={"title": "🧠 处理模型"}
        )
        show_stats: bool = Field(
            default=True, 
            description="在对话结束后显示性能统计",
            json_schema_extra={"title": "📊 显示统计"}
        )
        messages_to_consider: int = Field(
            default=6, 
            description="提取事实时参考的最近消息数量",
            json_schema_extra={"title": "🔍 上下文窗口"}
        )
        timezone: str = Field(
            default="Asia/Shanghai", 
            description="用于生成记忆时间戳的时区",
            json_schema_extra={"title": "🌍 时区"}
        )
        consolidation_threshold: float = Field(
            default=0.75, 
            description="判断记忆相似度的阈值 (0.0-1.0)",
            json_schema_extra={"title": "🔗 相似度阈值"}
        )
        summarize_after_n_memories: int = Field(
            default=10, 
            description="每新增多少条记忆触发一次整理",
            json_schema_extra={"title": "📦 整理频率"}
        )

    def __init__(self):
        self.valves = self.Valves()
        self.start_time: float = 0.0
        self.time_to_first_token: Optional[float] = None
        self.first_chunk_received: bool = False

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        """请求预处理：重置计时器"""
        self.start_time = time.time()
        self.time_to_first_token = None
        self.first_chunk_received = False
        return body

    def stream(self, event: dict) -> dict:
        """流式处理：捕获首字时间"""
        if not self.first_chunk_received:
            self.time_to_first_token = time.time() - self.start_time
            self.first_chunk_received = True
        return event

    async def outlet(self, body: dict, __event_emitter__: Callable[[Any], Awaitable[None]], __user__: Optional[dict] = None) -> dict:
        """响应后处理：执行记忆逻辑"""
        if not self.valves.enabled or not __user__ or len(body.get("messages", [])) < 2:
            return body

        user = Users.get_user_by_id(__user__["id"])
        conversation_end_time = time.time()

        # 核心逻辑：提取并保存记忆
        memory_result = {"status": "skipped", "message": ""}
        try:
            # 执行记忆处理
            memory_result = await self._process_memory(body, user)
        except Exception as e:
            print(f"[SuperMemory] Processing Error: {e}")
            memory_result = {"status": "error", "message": "处理出错"}

        # 统计信息展示
        if self.valves.show_stats:
            stats = self._calculate_stats(conversation_end_time)
            await self._show_status(__event_emitter__, memory_result, stats)

        return body

    # ==================== 核心逻辑 ====================

    async def _process_memory(self, body: dict, user: Any) -> Dict[str, Any]:
        """
        主流程：提取事实 -> 查重 -> 存储 -> (可选)触发摘要
        """
        conversation_text = self._stringify_conversation(body["messages"])
        
        # 1. 提取事实
        new_facts = await self._call_llm_json(FACT_EXTRACTION_PROMPT, conversation_text)
        if not new_facts:
            return {"status": "success", "message": "无新事实"}

        saved_count = 0
        updated_count = 0
        
        for fact in new_facts:
            if not isinstance(fact, str): continue # 类型安全检查

            # 2. 查重：查找相似记忆
            similar_memories = await self._query_similar_memories(fact, user)
            
            # 3. 智能判断：决定是跳过、更新还是新增
            action, target_ids = await self._analyze_relationship(fact, similar_memories)
            
            if action == "skip":
                continue
            
            # 4. 执行操作
            try:
                if action == "update" and target_ids:
                    for mid in target_ids:
                        await delete_memory_by_id(mid, user)
                    updated_count += 1
                else:
                    saved_count += 1
                
                # 存入新记忆 (带时间戳)
                await self._save_memory_native(fact, user)
            except Exception as e:
                print(f"[SuperMemory] Save/Update failed: {e}")
                continue
            
            # 检查是否需要触发后台整理
            self._increment_counter_and_trigger_summary(user)

        # 构建返回消息
        msg_parts = []
        if saved_count: msg_parts.append(f"新增{saved_count}")
        if updated_count: msg_parts.append(f"更新{updated_count}")
        
        return {
            "status": "success", 
            "message": ", ".join(msg_parts) if msg_parts else "信息已存在",
        }

    async def _save_memory_native(self, content: str, user: Any) -> None:
        """
        构建时间戳并调用系统 API 存储
        说明：使用 Request(scope=...) 是为了兼容 OpenWebUI 的 Router 内部调用机制
        """
        try:
            tz = pytz.timezone(self.valves.timezone)
        except pytz.UnknownTimeZoneError:
            tz = pytz.utc
            
        now_str = datetime.datetime.now(tz).strftime('%Y年%m月%d日%H点%M分')
        final_content = f"{now_str}：{content}"
        
        # Mock 一个 Request 对象，这是调用 Router 的必要条件
        req = Request(scope={"type": "http", "app": webui_app})
        await add_memory(req, AddMemoryForm(content=final_content), user)

    async def _query_similar_memories(self, content: str, user: Any) -> List[Dict[str, Any]]:
        """使用原生 API 查找相似记忆"""
        req = Request(scope={"type": "http", "app": webui_app})
        try:
            result = await query_memory(
                req, 
                QueryMemoryForm(content=content, k=5), 
                user
            )
            memories = []
            if result and hasattr(result, 'ids') and result.ids:
                ids = result.ids[0]
                docs = result.documents[0]
                dists = result.distances[0]
                
                for i, doc in enumerate(docs):
                    similarity = 1 - dists[i]
                    if similarity >= self.valves.consolidation_threshold:
                        memories.append({
                            "id": ids[i],
                            "content": doc,
                            "similarity": similarity
                        })
            return memories
        except Exception as e:
            print(f"[SuperMemory] Query error: {e}")
            return []

    async def _analyze_relationship(self, new_fact: str, similar_memories: List[dict]) -> Tuple[str, List[str]]:
        """判断新事实与旧记忆的关系"""
        if not similar_memories:
            return "new", []
        
        context_list = [m['content'] for m in similar_memories]
        prompt = (
            f"新信息: {new_fact}\n\n相关旧记忆:\n" 
            + "\n".join(context_list) 
            + "\n\n请判断关系，只返回单词: duplicate (重复), update (需更新旧记忆), new (新信息)"
        )
        
        try:
            res = await self._call_llm(prompt, system_prompt="你是一个去重判断器。")
            res = res.lower().strip()
            
            if "duplicate" in res:
                return "skip", []
            elif "update" in res:
                return "update", [m['id'] for m in similar_memories]
            else:
                return "new", []
        except Exception:
            # LLM 调用失败时，默认保守策略：存为新记忆
            return "new", []

    # ==================== 后台任务 ====================

    def _increment_counter_and_trigger_summary(self, user: Any) -> None:
        uid = user.id
        count = self._user_memory_counters.get(uid, 0) + 1
        self._user_memory_counters[uid] = count
        
        if count >= self.valves.summarize_after_n_memories:
            if uid not in self._summarization_running:
                self._user_memory_counters[uid] = 0
                asyncio.create_task(self._run_consolidation_task(user))

    async def _run_consolidation_task(self, user: Any) -> None:
        uid = user.id
        self._summarization_running.add(uid)
        try:
            # 可以在此实现更复杂的摘要合并逻辑
            # 目前仅作为占位，避免报错
            await asyncio.sleep(0.1) 
        except Exception as e:
            print(f"[SuperMemory] Consolidation task failed: {e}")
        finally:
            self._summarization_running.discard(uid)

    # ==================== 工具函数 ====================

    async def _call_llm(self, prompt: str, system_prompt: str = "") -> str:
        import aiohttp
        headers = {
            "Authorization": f"Bearer {self.valves.api_key}", 
            "Content-Type": "application/json"
        }
        payload = {
            "model": self.valves.model,
            "messages": [
                {"role": "system", "content": system_prompt}, 
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.0
        }
        async with aiohttp.ClientSession() as session:
            async with session.post(self.valves.api_url, headers=headers, json=payload) as resp:
                if resp.status != 200:
                    raise Exception(f"API Error: {resp.status}")
                data = await resp.json()
                return data["choices"][0]["message"]["content"].strip()

    async def _call_llm_json(self, system_prompt: str, user_prompt: str) -> List[str]:
        try:
            text = await self._call_llm(user_prompt, system_prompt)
            # 清理 Markdown 代码块
            if "```json" in text:
                text = text.split("```json")[1].split("```")[0]
            elif "```" in text:
                text = text.split("```")[1].split("```")[0]
            
            result = json.loads(text)
            return result if isinstance(result, list) else []
        except Exception as e:
            print(f"[SuperMemory] JSON parsing error: {e}")
            return []

    def _stringify_conversation(self, messages: List[dict]) -> str:
        # 排除 System Message，只看最近几轮
        valid_msgs = [m for m in messages if m['role'] in ('user', 'assistant')]
        return "\n".join([f"{m['role']}: {m['content']}" for m in valid_msgs[-self.valves.messages_to_consider:]])

    def _calculate_stats(self, end_time: float) -> Dict[str, str]:
        elapsed = end_time - self.start_time
        ttft = "N/A"
        if self.time_to_first_token is not None:
            ttft = f"{self.time_to_first_token:.2f}s"
            
        return {
            "elapsed": f"{elapsed:.2f}s",
            "ttft": ttft
        }

    async def _show_status(self, emitter: Callable, memory_res: Dict, stats: Dict) -> None:
        status_text = f"记忆: {memory_res['message']} | 首字: {stats['ttft']} | 耗时: {stats['elapsed']}"
        await emitter({
            "type": "status", 
            "data": {"description": status_text, "done": True}
        })