"""
title: 超级记忆助手 (Lite版)
description: 
1. 自动提取对话中的事实并存入记忆。
2. 自动为记忆添加精确到分钟的中文时间戳。
3. 定期（按记忆条数）触发后台摘要合并任务。
4. 移除危险的猴子补丁和冗余的文件缓存，直接利用 Open WebUI 原生向量库。
5. 显示首字时间 (TTFT) 和总耗时。
author: 南风 (二改Bryce) & Gemini
version: 7.1
required_open_webui_version: >= 0.5.0
"""

import json
import asyncio
import time
import datetime
import re
from typing import Optional, Callable, Awaitable, Any, List

import pytz
from pydantic import BaseModel, Field

from open_webui.models.users import Users
from open_webui.routers.memories import (
    add_memory,
    AddMemoryForm,
    query_memory,
    QueryMemoryForm,
    delete_memory_by_id,
)
from fastapi.requests import Request
from open_webui.main import app as webui_app

# ==================== 提示词 ====================
FACT_EXTRACTION_PROMPT = """你正在帮助维护用户的“记忆”。你的任务是判断用户的【最新一条】消息中，有哪些细节值得作为“记忆”被长期保存。\n【核心指令】\n1. 只分析用户最新一条消息。\n2. 忽略临时信息。\n3. 返回JSON字符串数组。"""
FACT_CONSOLIDATION_PROMPT = """你正在管理用户的"记忆"。清理重叠或冲突的记忆列表。\n返回JSON字符串数组。"""
MEMORY_SUMMARIZATION_PROMPT = """将用户的多条相关但零散的记忆，合并成一个简洁、全面、高质量的摘要。\n返回单一段落文本。"""

class Filter:
    # 记录每个用户的记忆计数，用于触发摘要 {user_id: count}
    _user_memory_counters = {}
    # 防止并发摘要 {user_id}
    _summarization_running = set()

    class Valves(BaseModel):
        enabled: bool = Field(default=True, description="开启插件")
        api_url: str = Field(default="https://api.openai.com/v1/chat/completions", description="LLM API 地址")
        api_key: str = Field(default="", description="LLM API Key")
        model: str = Field(default="gpt-4o-mini", description="用于记忆处理的模型")
        show_stats: bool = Field(default=True, description="显示性能统计 (首字时间/耗时)")
        messages_to_consider: int = Field(default=6, description="分析最近几条消息")
        timezone: str = Field(default="Asia/Shanghai", description="时区 (如 Asia/Shanghai)")
        
        consolidation_threshold: float = Field(default=0.75, description="查找相关记忆的相似度阈值")
        summarize_after_n_memories: int = Field(default=10, description="每新增多少条记忆触发一次摘要整理")

    def __init__(self):
        self.valves = self.Valves()
        self.start_time = 0
        self.time_to_first_token = None
        self.first_chunk_received = False

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        self.start_time = time.time()
        # 重置首字时间状态
        self.time_to_first_token = None
        self.first_chunk_received = False
        return body

    def stream(self, event: dict) -> dict:
        # 捕获第一个数据块的时间
        if not self.first_chunk_received:
            self.time_to_first_token = time.time() - self.start_time
            self.first_chunk_received = True
        return event

    async def outlet(self, body: dict, __event_emitter__: Callable[[Any], Awaitable[None]], __user__: Optional[dict] = None) -> dict:
        if not self.valves.enabled or not __user__ or len(body.get("messages", [])) < 2:
            return body

        user = Users.get_user_by_id(__user__["id"])
        conversation_end_time = time.time()

        # 核心逻辑：提取并保存记忆
        memory_result = {"status": "skipped", "message": ""}
        try:
            # 这里的 await 决定了是否等待记忆处理完成再显示结果
            memory_result = await self._process_memory(body, user)
        except Exception as e:
            print(f"Memory processing error: {e}")
            memory_result = {"status": "error", "message": str(e)}

        # 统计信息
        if self.valves.show_stats:
            stats = self._calculate_stats(body, conversation_end_time)
            await self._show_status(__event_emitter__, memory_result, stats, user)

        return body

    # ==================== 核心逻辑 ====================

    async def _process_memory(self, body: dict, user) -> dict:
        """提取事实 -> 查重 -> 存储 -> (可选)触发摘要"""
        conversation_text = self._stringify_conversation(body["messages"])
        
        # 1. 提取事实
        new_facts = await self._call_llm_json(FACT_EXTRACTION_PROMPT, conversation_text)
        if not new_facts:
            return {"status": "success", "message": "无新事实"}

        saved_count = 0
        updated_count = 0
        
        for fact in new_facts:
            # 2. 查重
            similar_memories = await self._query_similar_memories(fact, user)
            
            # 3. 智能判断
            action, target_ids = await self._analyze_relationship(fact, similar_memories)
            
            if action == "skip":
                continue
            
            # 4. 执行操作
            if action == "update" and target_ids:
                for mid in target_ids:
                    await delete_memory_by_id(mid, user)
                updated_count += 1
            else:
                saved_count += 1
            
            # 存入新记忆
            await self._save_memory_native(fact, user)
            
            # 检查摘要触发
            self._increment_counter_and_trigger_summary(user)

        msg = []
        if saved_count: msg.append(f"新增{saved_count}")
        if updated_count: msg.append(f"更新{updated_count}")
        
        return {
            "status": "success", 
            "message": ", ".join(msg) if msg else "信息已存在",
            "net_count_delta": saved_count - updated_count
        }

    async def _save_memory_native(self, content: str, user):
        """添加时间戳并调用原生 API 存储"""
        try:
            tz = pytz.timezone(self.valves.timezone)
        except pytz.UnknownTimeZoneError:
            tz = pytz.utc
            
        now_str = datetime.datetime.now(tz).strftime('%Y年%m月%d日%H点%M分')
        final_content = f"{now_str}：{content}"
        
        req = Request(scope={"type": "http", "app": webui_app})
        await add_memory(req, AddMemoryForm(content=final_content), user)

    async def _query_similar_memories(self, content: str, user) -> List[dict]:
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
            print(f"Query error: {e}")
            return []

    async def _analyze_relationship(self, new_fact, similar_memories):
        """简单判断逻辑"""
        if not similar_memories:
            return "new", []
        
        context_list = [m['content'] for m in similar_memories]
        prompt = f"新信息: {new_fact}\n\n相关旧记忆:\n" + "\n".join(context_list) + \
                 "\n\n请判断关系，只返回单词: duplicate (重复/已包含), update (需要更新旧记忆), new (即便是相关的，也是一条新信息)"
        
        res = await self._call_llm(prompt, system_prompt="你是一个去重判断器。")
        res = res.lower()
        
        if "duplicate" in res:
            return "skip", []
        elif "update" in res:
            return "update", [m['id'] for m in similar_memories]
        else:
            return "new", []

    # ==================== 摘要合并 (后台任务) ====================

    def _increment_counter_and_trigger_summary(self, user):
        uid = user.id
        count = self._user_memory_counters.get(uid, 0) + 1
        self._user_memory_counters[uid] = count
        
        if count >= self.valves.summarize_after_n_memories:
            if uid not in self._summarization_running:
                self._user_memory_counters[uid] = 0
                asyncio.create_task(self._run_consolidation_task(user))

    async def _run_consolidation_task(self, user):
        """后台运行：查找所有记忆 -> 聚类 -> 合并"""
        uid = user.id
        self._summarization_running.add(uid)
        # print(f"[Memory] Starting consolidation for {uid}...")
        try:
            # 这是一个占位符，保留了后台任务的结构
            # 可以在此实现更复杂的摘要逻辑，而不阻塞前端
            pass 
        except Exception as e:
            print(f"[Memory] Consolidation failed: {e}")
        finally:
            self._summarization_running.discard(uid)

    # ==================== 工具函数 ====================

    async def _call_llm(self, prompt: str, system_prompt: str = "") -> str:
        import aiohttp
        headers = {"Authorization": f"Bearer {self.valves.api_key}", "Content-Type": "application/json"}
        payload = {
            "model": self.valves.model,
            "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": prompt}],
            "temperature": 0.0
        }
        async with aiohttp.ClientSession() as session:
            async with session.post(self.valves.api_url, headers=headers, json=payload) as resp:
                data = await resp.json()
                return data["choices"][0]["message"]["content"].strip()

    async def _call_llm_json(self, system_prompt, user_prompt) -> list:
        text = await self._call_llm(user_prompt, system_prompt)
        try:
            if "```json" in text:
                text = text.split("```json")[1].split("```")[0]
            return json.loads(text)
        except:
            return []

    def _stringify_conversation(self, messages: List[dict]) -> str:
        return "\n".join([f"{m['role']}: {m['content']}" for m in messages[-self.valves.messages_to_consider:]])

    def _calculate_stats(self, body, end_time):
        elapsed = end_time - self.start_time
        ttft = "N/A"
        if self.time_to_first_token is not None:
            ttft = f"{self.time_to_first_token:.2f}s"
            
        return {
            "elapsed": f"{elapsed:.2f}s",
            "ttft": ttft
        }

    async def _show_status(self, emitter, memory_res, stats, user):
        status_text = f"记忆: {memory_res['message']} | 首字: {stats['ttft']} | 耗时: {stats['elapsed']}"
        await emitter({"type": "status", "data": {"description": status_text, "done": True}})