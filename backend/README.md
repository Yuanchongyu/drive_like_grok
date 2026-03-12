# 行程规划后端（Gemini）

根据用户自然语言 + 当前位置，用 Gemini 解析成有序站点列表，供 iOS 打开 Google 地图。

## 本地运行

```bash
cd backend
pip install -r requirements.txt
export GEMINI_API_KEY="你的 Gemini API Key"
# 可选：Google Places API Key（在 Google Cloud 开启 Places API），用于把「离我最近的麦当劳」自动解析成「一个具体地址」，地图直接导航不弹选择列表
# export GOOGLE_PLACES_API_KEY="你的 Google Cloud API Key"
python server.py
```

- 本机访问：<http://127.0.0.1:5000>
- **iOS 模拟器**访问本机：在 App 里把 `planServiceBaseURL` 设为 `http://localhost:5000`
- **真机**访问本机：把 `planServiceBaseURL` 改成你 Mac 的局域网 IP，如 `http://192.168.1.100:5000`（Mac 系统设置 → 网络 可看到 IP）

## 接口

- `POST /plan`  
  Body: `{ "userInput": "去学校接孩子然后去麦当劳再回家", "latitude": 49.28, "longitude": -123.12 }`  
  Response: `{ "waypoints": ["地点A", "地点B", "地点C"] }`

- `GET /health`  
  检查服务与 API Key 是否配置。

## 部署到云端

可部署到 Google Cloud Run、AWS Lambda、或任意支持 Python 的云服务，并设置 `GEMINI_API_KEY` 环境变量。部署后把 iOS App 里的 `planServiceBaseURL` 改为你的公网 URL（需 HTTPS）。
