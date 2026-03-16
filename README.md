[![English](https://img.shields.io/badge/English-README-blue)](./README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-当前-green)](./README.md)

# Drive like Grok

用自然语言说一段行程，AI 解析后按顺序打开地图导航。现在支持两种模式：

- 标准路线规划：说「去学校接孩子然后去最近的麦当劳再回家」即可规划路线并跳转 Google 地图
- Gemini Live 实时语音：支持边说边聊、打断、实时转写、工具调用后直接打开导航

## 功能

- **语音输入**：点麦克风开始说，再点结束；结束后自动规划路线并打开地图（也可在输入框打字后点「规划路线」）
- **Gemini Live 实时语音**：默认使用稳定的标准 Live，会在一轮结束后直接调用 `plan_route` 并打开 Google Maps
- **实时转写**：界面会显示「她听到你说」和「她正在说」，便于判断识别和回复是否正确
- **Live 连接测试**：设置页可单独测试 Gemini REST 和 Live WebSocket，排查 Key / 网络 / 配置问题
- **实验功能：情绪对话**：设置里可手动开启 `Affective Dialog` 预览能力；若失败会自动回退到标准 Live
- **自然语言解析**：后端用 Gemini 从一句话里抽出有序站点（如：学校 → 麦当劳 → 家）
- **最近门店**：若配置了 Google Places API，会把「最近的麦当劳」等解析成具体一个地址，地图直接导航不弹选择列表
- **多站路线**：起点为当前位置，途经点按顺序传入 Google 地图

## 技术栈

- **iOS**：SwiftUI、Speech（语音识别）、系统定位
- **后端**：Flask（Python）、Gemini API、可选 Google Places API
- **地图**：通过 URL 调起 Google 地图 App 或网页版

## 运行前准备

### 方式 A：端上直接调 API（推荐上架 App Store，无需自建后端）

- 每个用户**在 App 内填写自己的 API Key**：打开 App → 右上角「设置」→ 填写 **Gemini API Key**（必填，[Google AI Studio](https://aistudio.google.com/app/apikey) 免费申请）、**Places API Key**（可选，用于「最近的麦当劳」解析成具体地址）。
- Key 仅保存在**本机 Keychain**，不会上传；规划请求由手机直接发往 Gemini / Places，**不需要自建后端**。
- 未设置 Key 时，主界面会提示「请先设置你的 Gemini API Key」，点「规划路线」或麦克风也会先打开设置页。
- Live 默认使用 **标准 Gemini Live**（稳定优先）；如需尝试更强情绪反馈，可在设置中打开实验功能 **Affective Dialog**。

### 方式 B：自建后端（开发调试用）

1. 启动后端（Mac 本机）：
   ```bash
   cd backend
   pip install -r requirements.txt
   export GEMINI_API_KEY="你的 Gemini API Key"
   # 可选：export GOOGLE_PLACES_API_KEY="你的 Google Cloud API Key"
   python server.py
   ```
   - 默认端口 **5002**
2. 在 App 内**不要填写** Gemini API Key（或清空已保存的 Key），App 会改用 `ContentView.swift` 里的 `planServiceBaseURL` 访问你的后端
3. 将 `planServiceBaseURL` 改成你 Mac 的局域网 IP（如 `http://10.0.0.108:5002`），真机与 Mac 同一 WiFi

详见 [backend/README.md](backend/README.md)。

### iOS 权限

Info.plist 已配置：定位、本地网络（仅方式 B 需要）、麦克风、语音识别。

## Live 使用说明

### 默认行为

- 主界面的「说话」默认连接 **标准 Live**
- 用户说话结束后，模型会优先调用 `plan_route` 工具
- 跳转 Google Maps 后，App 会自动结束当前 Live 会话；返回 App 后回到初始待命状态

### 设置页可做的事情

- 测试 **Gemini REST 连接**
- 测试 **Live WebSocket 连接**
- 开关 **实验功能：情绪对话（Affective Dialog）**
- 配置 `Places API Key`

### 当前 Live 设计取舍

- 默认不开启 `Affective Dialog`，因为在部分 iOS 直连环境下，`v1alpha + enableAffectiveDialog` 可能不稳定
- 若用户手动开启实验功能但连接失败，App 会自动回退到标准 Live
- 为减少模型“听到自己”的问题，当前实现叠加了：
  - `voiceChat` 音频会话模式
  - 播放时的本地上行门控
  - 本地 3 秒静音判定后再发送 `activityEnd`

### 推荐说法

更容易触发导航的说法：

- `帮我导航去公司，然后去机场`
- `规划路线，先去学校接孩子，再去最近的麦当劳`
- `从我这里先去 SFU 看日落，再找最近的麦当劳，然后打开地图`

## 项目结构

```
drive_like_grok/
├── README.md                 # 本文件
├── drive_like_grok.xcodeproj
├── drive_like_grok/          # iOS 工程
│   ├── ContentView.swift     # 主界面、语音按钮、规划入口
│   ├── ApiKeySettingsView.swift
│   ├── ApiKeyStore.swift
│   ├── GeminiLiveService.swift
│   ├── GoogleMapsOpener.swift
│   ├── LiveMicCapture.swift
│   ├── LiveSessionManager.swift
│   ├── LiveWebSocketNW.swift
│   ├── LocationProvider.swift
│   ├── OnDeviceTripPlanningService.swift
│   ├── TripPlanningService.swift
│   ├── VoiceFeedbackHelper.swift
│   ├── VoiceInputHelper.swift
│   └── Info.plist
└── backend/
    ├── README.md
    ├── requirements.txt
    └── server.py             # /plan、/health，Gemini + Places
```

## 环境变量（后端）

| 变量 | 必填 | 说明 |
|------|------|------|
| `GEMINI_API_KEY` | 是 | Gemini API 密钥 |
| `GOOGLE_PLACES_API_KEY` 或 `PLACES_API_KEY` | 否 | 用于解析「最近/附近」到具体地址 |
| `PORT` | 否 | 默认 5002 |
| `GEMINI_MODEL` | 否 | 默认 `gemini-2.5-flash` |

## 发布到 App Store（免费版）

- 使用 **方式 A**：用户各自在 App 内设置自己的 Gemini / Places API Key，无需你部署后端，也无需在应用里写死任何 Key。
- 建议在 App 说明或设置页里提示用户：到 [Google AI Studio](https://aistudio.google.com/app/apikey) 申请免费 Gemini Key，并在 Google Cloud 控制台为该 Key 设置用量配额（按自己用量控制）。

## 后续可做

- CarPlay 支持
- 高德 / 百度地图等打开方式
- 若需完全隐藏 Key：可保留一个小型后端（如 Cloud Run）只做代理转发 Gemini/Places 请求
- 继续优化 Live 音频播放平滑度与首包时延
- 进一步提升长句路线确认和多轮澄清体验

## License

MIT
