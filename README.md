# Tools

自用实用工具和脚本集合

## 使用方法

```bash
# 运行可执行脚本
./bin/pexels-dw       # 从 STDIN 输入 JSON/文本，自动提取 https 链接并下载
./bin/tools-use-test  # 测试 LLM 工具调用

# 示例：将 JSON 管道到下载脚本
cat <<'JSON' | ./bin/pexels-dw
{
	"download_urls": [
		"https://example.com/video1.mp4?sig=123",
		"https://example.com/video2.mp4"
	]
}
JSON
```
