"""
title: 超级记忆助手 (Pro Max)
description: v7.6 - 包含历史清洗与上下文感知。根据 Code Review 进行了深度工程化重构，优化了代码可读性、类型安全及边界条件处理。
author: 南风 (二改Bryce) & Gemini
version: 7.6
required_open_webui_version: >= 0.5.0
"""

import json
import asyncio
import time
import datetime
from typing import Optional, Any, List, Dict, Tuple

import pytz
from pydantic import BaseModel, Field
from fastapi.requests import Request

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

FACT_EXTRACTION_PROMPT = """你是一个专业的【用户画像侧写师】。你的唯一任务是从对话中提取关于用户的**长期事实**。

【输入格式】
1. [Context] AI: AI 刚才说的话
2. [Target] User: 用户的最新发言

【提取逻辑】
1. **如果是 提问/查询/指令** (如 "NVIDIA股价?", "分析财报") -> 🛑 **忽略**。
2. **如果是 闲聊** -> 🛑 **忽略**。
3. **如果是 自我披露/陈述事实** (如 "我是设计师", "我不吃辣") -> ✅ **记录**。
4. **如果是 回答/确认** -> ✅ **结合 Context 记录**。

【输出格式】
只返回 JSON 字符串数组。无事实返回 `[]`。
"""

MEMORY_CLEANUP_PROMPT = """你是一名【记忆数据库审计员】。你将收到一份用户的记忆列表。
其中包含了很多**错误的垃圾数据**。

【删除标准 - 遇到以下情况必须删除】
1. 🗑️ **伪装成兴趣的提问**："用户关注..." (其实只是问了一句)
2. 🗑️ **归因错误**："用户分析了..." (其实是AI分析的)
3. 🗑️ **临时信息**："用户询问..."

【保留标准】
✅ 用户属性、明确偏好、长期工具

【输出格式】
只返回一个包含要删除 ID 的 JSON 字符串数组。例如：["id_1", "id_3"]。如果没有要删除的，返回 []。
"""

class Filter:
    # 类变量
    _user_memory_counters: Dict[str, int] = {}
    _summarization_running: set = set()

    class Valves(BaseModel):
        enabled: bool = Field(
            default=True, 
            description="开启或关闭插件功能",
            json_schema_extra={"title": "🔌 启用插件"}
        )
        # ==================== 清洗开关 ====================
        enable_retroactive_cleanup: bool = Field(
            default=False, 
            description="开启后，每次对话触发后台任务，扫描并删除错误的记忆。清洗完成后请务必关闭！",
            json_schema_extra={"title": "🧹 开启历史清洗模式 (用完即关)"}
        )
        cleanup_batch_size: int = Field(
            default=50,
            description="每次清洗扫描的记忆条数 (建议 50-100)",
            json_schema_extra={"title": "🧹 单次扫描数量"}
        )
        # ====================================================
        api_url: str = Field(
            default="https://api.openai.com/v1/chat/completions", 
            description="LLM API 地址",
            json_schema_extra={"title": "🤖 API 地址"}
        )
        api_key: str = Field(
            default="", 
            description="LLM API Key",
            json_schema_extra={"title": "🔑 API Key"}
        )
        model: str = Field(
            default="gpt-4o-mini", 
            description="模型",
            json_schema_extra={"title": "🧠 处理模型"}
        )
        show_stats: bool = Field(
            default=True, 
            description="显示统计",
            json_schema_extra={"title": "📊 显示统计"}
        )
        messages_to_consider: int = Field(
            default=2, 
            description="上下文窗口",
            json_schema_extra={"title": "🔍 分析窗口"}
        )
        timezone: str = Field(
            default="Asia/Shanghai", 
            description="时区",
            json_schema_extra={"title": "🌍 时区"}
        )
        consolidation_threshold: float = Field(
            default=0.75, 
            description="相似度阈值",
            json_schema_extra={"title": "🔗 相似度阈值"}
        )
        summarize_after_n_memories: int = Field(
            default=10, 
            description="整理频率",
            json_schema_extra={"title": "📦 整理频率"}
        )

    def __init__(self):
        self.valves = self.Valves()
        self.start_time: float = 0.0
        self.time_to_first_token: Optional[float] = None
        self.first_chunk_received: bool = False

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        self.start_time = time.time()
        self.time_to_first_token = None
        self.first_chunk_received = False
        return body

    def stream(self, event: dict) -> dict:
        if not self.first_chunk_received:
            self.time_to_first_token = time.time() - self.start_time
            self.first_chunk_received = True
        return event

    async def outlet(self, body: dict, __event_emitter__: Any, __user__: Optional[dict] = None) -> dict:
        """主输出处理逻辑"""
        if not self.valves.enabled or not __user__ or len(body.get("messages", [])) < 2:
            return body

        user = Users.get_user_by_id(__user__["id"])
        conversation_end_time = time.time()

        # 初始化结果对象
        memory_result: Dict[str, Any] = {"status": "skipped", "message": ""}
        
        # 分支逻辑：清洗模式 vs 正常模式
        if self.valves.enable_retroactive_cleanup:
            # 启动清洗任务
            asyncio.create_task(self._run_retroactive_cleanup(user))
            memory_result = {
                "status": "success",
                "message": "🧹 历史清洗已启动"
            }
        else:
            # 正常记忆处理
            try:
                memory_result = await self._process_memory(body, user)
            except Exception as e:
                print(f"[SuperMemory] Processing Error: {e}")
                memory_result = {
                    "status": "error",
                    "message": "⚠️ 处理异常"
                }

        # 显示状态栏
        if self.valves.show_stats:
            stats = self._calculate_stats(conversation_end_time)
            await self._show_status(__event_emitter__, memory_result, stats)

        return body

    # ==================== 🧹 历史清洗逻辑 ====================

    async def _run_retroactive_cleanup(self, user: Any) -> None:
        """后台任务：拉取旧记忆 -> LLM 审计 -> 删除垃圾"""
        # 1. 参数防御性检查
        batch_size = self.valves.cleanup_batch_size
        if batch_size <= 0:
            print("[Cleaner] Batch size invalid, skip.")
            return

        print(f"[Cleaner] Starting cleanup task for user {user.id} (Batch: {batch_size})...")
        
        req = Request(scope={"type": "http", "app": webui_app})
        try:
            # 使用空格作为通配符查询，这是 Vector DB 的常见 Trick
            result = await query_memory(req, QueryMemoryForm(content=" ", k=batch_size), user)
            
            # 检查查询结果有效性
            if not (result and hasattr(result, 'ids') and result.ids and result.ids[0]):
                print("[Cleaner] No memories found to clean.")
                return

            ids = result.ids[0]
            docs = result.documents[0]
            
            # 2. 构建审计数据
            memory_list_str = ""
            valid_batch_ids = []
            
            for i, content in enumerate(docs):
                mem_id = ids[i]
                valid_batch_ids.append(mem_id)
                memory_list_str += f"ID: {mem_id} | Content: {content}\n"

            if not memory_list_str:
                return

            # 3. LLM 审计
            print(f"[Cleaner] Auditing {len(valid_batch_ids)} memories...")
            ids_to_delete = await self._call_llm_json(MEMORY_CLEANUP_PROMPT, memory_list_str)
            
            if not ids_to_delete:
                print("[Cleaner] Audit passed. No garbage found.")
                return

            # 4. 执行删除
            deleted_count = 0
            for mid in ids_to_delete:
                if mid in valid_batch_ids:
                    try:
                        await delete_memory_by_id(mid, user)
                        deleted_count += 1
                        print(f"[Cleaner] Deleted garbage: {mid}")
                    except Exception as e:
                        print(f"[Cleaner] Delete failed {mid}: {e}")
            
            print(f"[Cleaner] Cleanup complete. Deleted {deleted_count} items.")

        except Exception as e:
            print(f"[Cleaner] Critical Error: {e}")

    # ==================== 正常记忆流程 ====================

    async def _process_memory(self, body: dict, user: Any) -> Dict[str, Any]:
        """处理新对话，提取事实并存储"""
        # 1. 构建上下文
        context_str = self._build_context_string(body["messages"])
        if not context_str:
            return {"status": "skipped", "message": "🔍 无有效上下文"}

        # 2. 提取事实
        new_facts = await self._call_llm_json(FACT_EXTRACTION_PROMPT, context_str)
        if not new_facts:
            return {"status": "success", "message": "💨 无新事实"}

        saved_count = 0
        updated_count = 0
        
        # 3. 逐条处理事实
        for fact in new_facts:
            if not isinstance(fact, str):
                continue 
            
            # 查重
            similar_memories = await self._query_similar_memories(fact, user)
            
            # 关系判断
            action, target_ids = await self._analyze_relationship(fact, similar_memories)
            
            if action == "skip":
                continue
            
            # 执行存储/更新
            try:
                if action == "update" and target_ids:
                    for mid in target_ids:
                        await delete_memory_by_id(mid, user)
                    updated_count += 1
                else:
                    saved_count += 1
                
                await self._save_memory_native(fact, user)
            except Exception as e:
                print(f"[SuperMemory] Save Error: {e}")
                continue
            
            # 触发摘要计数
            self._increment_counter_and_trigger_summary(user)

        # 构建返回信息（带 emoji 美化）
        msg_parts = []
        if saved_count:
            msg_parts.append(f"✨ 新增 {saved_count}")
        if updated_count:
            msg_parts.append(f"🔄 更新 {updated_count}")

        final_message = " · ".join(msg_parts) if msg_parts else "💭 无需记忆"
        return {"status": "success", "message": final_message}

    # ==================== 辅助方法 ====================

    def _build_context_string(self, messages: List[dict]) -> str:
        """构建 [AI] -> [User] 的上下文对，用于准确的意图识别"""
        if not messages:
            return ""
            
        last_user_idx = -1
        # 倒序查找最后一条用户消息
        for i in range(len(messages) - 1, -1, -1):
            if messages[i]['role'] == 'user':
                last_user_idx = i
                break
                
        if last_user_idx == -1:
            return ""
            
        target_user_msg = messages[last_user_idx]['content']
        context_ai_msg = "无"
        
        # 获取该用户消息的前一条 AI 消息（如果存在）
        if last_user_idx > 0 and messages[last_user_idx - 1]['role'] == 'assistant':
            context_ai_msg = messages[last_user_idx - 1]['content']
            
        return f"[Context] AI: {context_ai_msg}\n[Target] User: {target_user_msg}"

    async def _save_memory_native(self, content: str, user: Any) -> None:
        """调用系统 API 存储记忆，带时间戳"""
        try:
            tz = pytz.timezone(self.valves.timezone)
        except pytz.UnknownTimeZoneError:
            tz = pytz.utc
            
        now_str = datetime.datetime.now(tz).strftime('%Y年%m月%d日%H点%M分')
        final_content = f"{now_str}：{content}"
        
        req = Request(scope={"type": "http", "app": webui_app})
        await add_memory(req, AddMemoryForm(content=final_content), user)

    async def _query_similar_memories(self, content: str, user: Any) -> List[Dict[str, Any]]:
        """查询相似记忆"""
        req = Request(scope={"type": "http", "app": webui_app})
        try:
            result = await query_memory(req, QueryMemoryForm(content=content, k=5), user)
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
        except Exception:
            return []

    async def _analyze_relationship(self, new_fact: str, similar_memories: List[dict]) -> Tuple[str, List[str]]:
        """分析新旧记忆关系：duplicate / update / new"""
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
            
            # 代码解压，提高可读性
            if "duplicate" in res:
                return "skip", []
            elif "update" in res:
                return "update", [m['id'] for m in similar_memories]
            else:
                return "new", []
        except Exception:
            # 出错时默认作为新记忆存储，避免丢失信息
            return "new", []

    def _increment_counter_and_trigger_summary(self, user: Any) -> None:
        """简单的摘要触发计数器"""
        uid = user.id
        count = self._user_memory_counters.get(uid, 0) + 1
        self._user_memory_counters[uid] = count
        
        if count >= self.valves.summarize_after_n_memories:
            if uid not in self._summarization_running:
                self._user_memory_counters[uid] = 0
                asyncio.create_task(self._run_consolidation_task(user))

    async def _run_consolidation_task(self, user: Any) -> None:
        """后台摘要任务占位符"""
        uid = user.id
        self._summarization_running.add(uid)
        try:
            await asyncio.sleep(0.1)
        except Exception:
            pass
        finally:
            self._summarization_running.discard(uid)

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
            # 兼容 Markdown 代码块格式
            if "```json" in text:
                text = text.split("```json")[1].split("```")[0]
            elif "```" in text:
                text = text.split("```")[1].split("```")[0]
                
            result = json.loads(text)
            return result if isinstance(result, list) else []
        except Exception:
            return []

    def _calculate_stats(self, end_time: float) -> Dict[str, str]:
        elapsed = end_time - self.start_time
        ttft = "N/A"
        if self.time_to_first_token is not None:
            ttft = f"{self.time_to_first_token:.2f}s"
        return {"elapsed": f"{elapsed:.2f}s", "ttft": ttft}

    async def _show_status(self, emitter: Any, memory_res: Dict[str, Any], stats: Dict[str, str]) -> None:
        """在 UI 上显示状态信息（带 emoji 美化）"""
        # 根据状态选择不同的 emoji
        status_emoji = {
            "success": "🧠",
            "error": "❌",
            "skipped": "⏭️",
        }.get(memory_res.get("status", "skipped"), "📝")

        # 构建美观的状态栏
        status_text = (
            f"{status_emoji} {memory_res.get('message', '')}  "
            f"⚡ {stats['ttft']}  "
            f"⏱️ {stats['elapsed']}"
        )
        await emitter({
            "type": "status",
            "data": {"description": status_text, "done": True}
        })