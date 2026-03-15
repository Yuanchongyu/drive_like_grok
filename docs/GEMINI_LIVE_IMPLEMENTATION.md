# 接入 Gemini Multimodal Live API 实现方案

目标：让人声不机械、中英文混说自然、支持无缝打断和情感反馈，让 Agent 像真人一样和用户交流。

---

## 一、为什么用 Live API 能解决你的需求

| 需求 | Live API 能力 | 说明 |
|------|----------------|------|
| **人声不机械** | **Native Audio** | 使用 `gemini-2.5-flash-native-audio-preview-12-2025`，直接输出 24kHz PCM 人声，无需 TTS，语气自然 |
| **中英文混说** | **多语言 + 自动语言选择** | 支持约 70 种语言；Native Audio 会根据内容自动选语言，中英混合无需额外配置 |
| **无缝打断** | **Barge-in (VAD)** | 服务端 VAD 检测到用户说话会取消当前回复，并下发 `serverContent.interrupted`，客户端停止播放并清缓冲即可 |
| **情感反馈** | **Affective Dialog** | 开启 `enableAffectiveDialog: true`（需 v1alpha），模型会根据用户语气调整回复风格 |

当前架构是：**本地 STT → Gemini 文本 API 规划行程 → 本地 TTS 读回复**。  
接入 Live API 后改为：**麦克风 PCM 直连 Live API ↔ 实时双向语音**，行程规划通过 **Tool/Function Calling** 由 App 执行，模型只负责对话和播报。

---

## 二、技术规格（必读）

- **协议**：WSS（WebSocket over TLS）
- **端点**（API Key）：  
  `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=YOUR_API_KEY`
- **情感对话**需用 **v1alpha**：  
  `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=YOUR_API_KEY`
- **输入音频**：16-bit PCM，16kHz，little-endian，通过 `realtimeInput.audio` 发送，`mimeType: "audio/pcm;rate=16000"`
- **输出音频**：16-bit PCM，24kHz，little-endian，在 `serverContent.modelTurn.parts[].inlineData` 里，需实时播放
- **首条消息**：必须先发一条只含 `config` 的 `LiveSessionRequest`（见下节）

---

## 三、连接与配置流程

### 1. 建立 WebSocket

用 iOS 自带的 `URLSessionWebSocketTask` 即可（无需第三方库）：

```swift
let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)")!
var request = URLRequest(url: url)
request.timeoutIntervalForRequest = 60
let task = URLSession.shared.webSocketTask(with: request)
task.resume()
```

### 2. 发送首条配置（Setup）

第一条消息必须是 **config**（不包含 `realtimeInput`）：

```json
{
  "config": {
    "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
    "responseModalities": ["AUDIO"],
    "systemInstruction": {
      "parts": [{ "text": "你是路线规划助手，像 Grok 一样和用户对话。用户会说想去哪些地方，你会确认行程并用自然语气回复。当需要规划路线时，请调用 plan_route 工具，不要自己编地址。" }]
    }
  }
}
```

若要**情感反馈**，改用 **v1alpha** 端点并在 config 里加：

```json
"enableAffectiveDialog": true
```

（v1alpha 的 config 字段名可能为 camelCase，以官方 API 文档为准。）

### 3. 之后发送音频

把麦克风采集到的 16kHz、16-bit、little-endian PCM 按块（例如每 20ms 一包）用 `realtimeInput` 发送：

```json
{
  "realtimeInput": {
    "audio": {
      "data": "<base64 编码的 PCM>",
      "mimeType": "audio/pcm;rate=16000"
    }
  }
}
```

用户停止说话超过约 1 秒时，建议发一次「流结束」标记（若 API 支持 `realtimeInput.audioStreamEnd`），便于服务端 VAD 判定结束。

---

## 四、接收与播放

### 1. 解析 serverContent

每条 WebSocket 下行可能是 `LiveSessionResponse`，重点处理：

- **`serverContent.modelTurn.parts`**  
  每个 `part` 里若有 `inlineData`，则为一段 24kHz PCM，解码 base64 后送入播放器。
- **`serverContent.interrupted`**  
  为 `true` 表示用户打断了，**必须**：停止当前播放、清空未播放的 PCM 队列，然后继续接收新的回复。
- **`serverContent.inputTranscription`**  
  用户说话的转写（可选，用于调试或 UI）。
- **`serverContent.outputTranscription`**  
  模型回复的转写（可选）。
- **`toolCall`**  
  模型请求调用工具（见下一节）。

### 2. 实时播放 24kHz PCM

- 用 **AVAudioEngine** + **AVAudioPlayerNode**，或 **Audio Unit** 的 RemoteIO，按 24kHz、单声道、16-bit 播放。
- 收到 `interrupted == true` 时：立即 stop 播放、清空 buffer，不再播放此前收到的 PCM。

这样即可实现「用户一说话，Agent 立刻停」的无缝打断。

---

## 五、行程规划与 Tool Calling

让 Live 模型只负责对话和确认，具体路线由现有逻辑执行：

1. **在 systemInstruction 里说明**：需要规划路线时调用 `plan_route`，参数为站点列表。
2. **在 config 里声明工具**（具体字段名以 [Live API 文档](https://ai.google.dev/gemini-api/docs/live-tools) 为准），例如：

```json
"tools": [{
  "functionDeclarations": [{
    "name": "plan_route",
    "description": "根据用户说的站点顺序规划驾车路线并打开地图",
    "parameters": {
      "type": "object",
      "properties": {
        "waypoints": {
          "type": "array",
          "items": { "type": "string" },
          "description": "按顺序的站点名称或地址"
        }
      },
      "required": ["waypoints"]
    }
  }]
}]
```

3. **收到 `toolCall` 时**：  
   - 解析 `functionCalls`，若为 `plan_route`，则用现有 `OnDeviceTripPlanningService`（或只取 waypoints 调用 `GoogleMapsOpener.openDirections`）执行。  
   - 然后把结果通过 **toolResponse** 发回 WebSocket：

```json
{
  "toolResponse": {
    "functionResponses": [{
      "name": "plan_route",
      "id": "<toolCall 里的 id>",
      "response": { "result": { "success": true, "message": "已打开地图" } }
    }]
  }
}
```

这样 Agent 会继续用语音说「已经帮你打开地图啦」之类，并由 Native Audio 自然播报。

---

## 六、音频管线（iOS 侧）

### 1. 采集 16kHz PCM

- 使用 **AVAudioEngine** + `inputNode`，格式设为 16kHz、单声道、16-bit PCM（或设备格式 + 转换）。
- 在 `installTap` 的回调里把 buffer 转为 16-bit 16kHz（若需要可先重采样），再 base64 后通过 WebSocket 发送。

### 2. 播放 24kHz PCM

- 维护一个 **线程安全** 的 PCM 队列。
- 用 **AVAudioEngine** + **AVAudioPlayerNode** + **AVAudioPCMBuffer**（24kHz, 1 channel, 16-bit），从队列取数据填充 buffer 并 schedule 播放。
- 收到 **interrupted** 时清空队列并 stop 当前播放。

### 3. 会话与权限

- 录音前设置 `AVAudioSession` 为 `.playAndRecord`（或至少支持录音），以便同时播放 Agent 声音和采集用户声音。
- 若使用「按住说话」而非持续流，可在松手时发 `audioStreamEnd`（若 API 支持），便于服务端区分一句话结束。

---

## 七、实现步骤小结

1. **新建 `GeminiLiveService`**  
   - 管理 WebSocket 连接（URLSessionWebSocketTask）。  
   - 发送首条 config（含 systemInstruction、可选 tools、可选 enableAffectiveDialog）。  
   - 接收循环：解析 `serverContent`、interrupted、modelTurn.parts、toolCall。

2. **音频采集**  
   - 在现有或新模块里用 AVAudioEngine 输出 16kHz 16-bit PCM，交给 `GeminiLiveService` 发送。

3. **音频播放**  
   - 在 Service 或单独 Player 中实现 24kHz PCM 播放；收到 `interrupted` 立即停播并清队列。

4. **Tool 集成**  
   - 在 `toolCall` 里调用现有 `TripPlanningService` + `GoogleMapsOpener`，再回传 `toolResponse`。

5. **UI 与模式**  
   - 可保留「点击说话」：按下即建立 Live 连接并开始送音，松开发 audioStreamEnd（或断开），或改为「长连对话」：进入即连、一直送音直到用户退出。  
   - 显示状态：连接中、听筒中、播放中、被打断等。

6. **情感与 v1alpha**  
   - 需要情感反馈时改用 v1alpha 端点并设 `enableAffectiveDialog: true`。

按上述步骤即可实现：**人声自然、中英混说、无缝打断、带情感的对话**，并把行程规划继续交给现有逻辑执行。

---

## 八、参考链接

- [Live API 概述](https://ai.google.dev/gemini-api/docs/multimodal-live)
- [Live API 能力指南](https://ai.google.dev/gemini-api/docs/live-guide)（含 VAD、Affective Dialog）
- [WebSocket 接入](https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket)
- [Live API WebSockets 参考](https://ai.google.dev/api/live)
- [Tool use](https://ai.google.dev/gemini-api/docs/live-tools)
