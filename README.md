# Drive like Grok

用自然语言说一段行程，AI 解析后按顺序打开地图导航。支持语音输入，说「去学校接孩子然后去最近的麦当劳再回家」即可规划路线并跳转 Google 地图。

## 功能

- **语音输入**：点麦克风开始说，再点结束；结束后自动规划路线并打开地图（也可在输入框打字后点「规划路线」）
- **自然语言解析**：后端用 Gemini 从一句话里抽出有序站点（如：学校 → 麦当劳 → 家）
- **最近门店**：若配置了 Google Places API，会把「最近的麦当劳」等解析成具体一个地址，地图直接导航不弹选择列表
- **多站路线**：起点为当前位置，途经点按顺序传入 Google 地图

## 技术栈

- **iOS**：SwiftUI、Speech（语音识别）、系统定位
- **后端**：Flask（Python）、Gemini API、可选 Google Places API
- **地图**：通过 URL 调起 Google 地图 App 或网页版

## 运行前准备

### 1. 后端（Mac 本机）

```bash
cd backend
pip install -r requirements.txt
export GEMINI_API_KEY="你的 Gemini API Key"
# 可选：把「最近的麦当劳」解析成具体地址
# export GOOGLE_PLACES_API_KEY="你的 Google Cloud API Key"
python server.py
```

- 默认端口 **5002**（与 iOS 内 `planServiceBaseURL` 一致）
- 详见 [backend/README.md](backend/README.md)

### 2. iOS App

- 用 Xcode 打开 `drive_like_grok.xcodeproj`
- **真机 / 模拟器访问本机后端**：在 `ContentView.swift` 里把 `planServiceBaseURL` 改成你 Mac 的局域网 IP（如 `http://10.0.0.108:5002`），真机需与 Mac 同一 WiFi
- 如需本地网络权限：Info.plist 已配置 `NSLocalNetworkUsageDescription`、麦克风、语音识别、定位

## 项目结构

```
drive_like_grok/
├── README.md                 # 本文件
├── drive_like_grok.xcodeproj
├── drive_like_grok/          # iOS 工程
│   ├── ContentView.swift     # 主界面、语音按钮、规划入口
│   ├── GoogleMapsOpener.swift
│   ├── LocationProvider.swift
│   ├── TripPlanningService.swift
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

## 后续可做

- CarPlay 支持
- 高德 / 百度地图等打开方式
- 云端部署后端（HTTPS），App 改用公网 URL

## License

MIT
