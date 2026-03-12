"""
行程规划后端：接收用户输入 + 当前位置，用 Gemini 解析成有序站点列表。
运行：在项目根目录执行
  pip install -r backend/requirements.txt
  export GEMINI_API_KEY="你的 Gemini API Key"
  python backend/server.py
本地访问：http://127.0.0.1:5000
iOS 模拟器访问本机：http://localhost:5000 或 Mac 的局域网 IP（如 http://192.168.x.x:5000）
"""

import math
import os
import json
import re
import traceback
import urllib.parse
import urllib.request
from flask import Flask, request, jsonify

app = Flask(__name__)

# 从环境变量读取，不要写死在代码里
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
# 可选：Google Places API Key（需在 Google Cloud 开启 Places API），用于把「最近的麦当劳」解析成具体一个地址
PLACES_API_KEY = os.environ.get("GOOGLE_PLACES_API_KEY") or os.environ.get("PLACES_API_KEY")
# 可选：模型名。gemini-1.5-flash 在某些 API 版本中已不可用，改用 gemini-2.5-flash 或 gemini-2.0-flash-exp
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
if not GEMINI_API_KEY:
    print("Warning: GEMINI_API_KEY not set. Set it with: export GEMINI_API_KEY='your-key'")


def call_gemini(user_input: str, latitude: float | None, longitude: float | None) -> list[str]:
    """调用 Gemini，根据用户输入和当前位置解析出有序站点（地址或可搜索的名称）。"""
    try:
        import google.generativeai as genai
        genai.configure(api_key=GEMINI_API_KEY)
        model = genai.GenerativeModel(GEMINI_MODEL)
    except Exception as e:
        raise RuntimeError(f"Gemini 初始化失败: {e}") from e

    location_line = ""
    if latitude is not None and longitude is not None:
        location_line = f"用户当前所在位置（经纬度）: ({latitude}, {longitude})。请根据「当前位置」理解「附近」「最近」「离这里最近的」等表述，并尽量给出该区域内的具体地点名称或地址（如城市、街道）。\n\n"

    prompt = f"""你是路线规划助手。{location_line}从用户的话里「按顺序」抽出每一站的地名或地址，输出成一个 JSON 数组。每个元素只能是「一个地点」，不能把用户整句话当成一个元素。

规则：
1. 只输出一个 JSON 数组，不要任何解释、markdown 或代码块。
2. 示例：用户说「去 XX 学校接孩子，然后去麦当劳，再回家」→ 输出 ["XX学校", "最近的麦当劳", "家"]（三个字符串）。若用户只说「去麦当劳」「去星巴克」等未指定具体门店，一律输出「最近的麦当劳」「最近的星巴克」，方便系统自动选最近门店。
3. 示例：用户说「先去 A 再去 B 最后回 C」→ 输出 ["A", "B", "C"]。
4. 禁止输出 ["用户说的整句话"] 这种只有一个长字符串的数组；必须拆成多个短字符串，每个字符串一个地点。
5. 若提到「家」「回家」，输出 "家" 或加城市如 "Vancouver BC"；若提到学校/接孩子，输出具体校名或「XX学校」+ 城市。
6. 每个字符串要能在地图里搜到（可带城市、省/州）。

用户输入：
{user_input}

请只输出 JSON 数组："""

    response = model.generate_content(
        prompt,
        generation_config=genai.types.GenerationConfig(
            temperature=0.2,
            max_output_tokens=1024,
        ),
    )
    text = (response.text or "").strip()

    # 尝试从回复中解析 JSON 数组
    json_match = re.search(r"\[[\s\S]*?\]", text)
    if json_match:
        try:
            waypoints = json.loads(json_match.group())
            if isinstance(waypoints, list) and all(isinstance(w, str) for w in waypoints):
                cleaned = [w.strip() for w in waypoints if w.strip()]
                # 若模型只返回了一整句（一个很长或和用户输入很像的元素），尝试按「然后」「再」等拆成多站
                if len(cleaned) == 1 and len(cleaned[0]) > 30:
                    for sep in ["然后", "再", "接着", "最后去", "再去", "再去"]:
                        parts = re.split(sep, cleaned[0], flags=re.IGNORECASE)
                        if len(parts) > 1:
                            cleaned = [p.strip().strip("，。、") for p in parts if p.strip()]
                            break
                if cleaned:
                    return cleaned
        except json.JSONDecodeError:
            pass

    # 解析失败时尝试按常见连接词拆分用户原话
    for sep in ["然后", "再", "接着", "最后", "再去"]:
        parts = re.split(sep, user_input.strip())
        if len(parts) > 1:
            return [p.strip().strip("，。、去") for p in parts if p.strip()]
    return [user_input.strip()] if user_input.strip() else []


def _distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """粗略计算两点距离（公里），用于排序「最近」."""
    R = 6371
    a = math.radians(lat2 - lat1)
    b = math.radians(lon2 - lon1)
    x = math.sin(a / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(b / 2) ** 2
    return 2 * R * math.asin(math.sqrt(min(1, x)))


def resolve_to_single_place(query: str, latitude: float, longitude: float) -> str | None:
    """用 Google Places 把「最近的 XXX」解析成「一个具体地址」，选真正最近的一个，地图直接导航不弹选择列表。"""
    if not PLACES_API_KEY or not query.strip():
        return None
    q = query.strip().lower()
    # 触发解析：品牌/品类词 或 明确说「最近/附近」
    resolve_keywords = (
        "麦当劳", "mcdonald", "星巴克", "starbucks", "咖啡", "肯德基", "kfc", "加油站", "gas station",
        "超市", "银行", "最近", "附近", "nearest", "near me", "离我", "最近的",
    )
    if not any(kw in q or kw in query for kw in resolve_keywords):
        return None
    try:
        params = {
            "input": query.strip(),
            "inputtype": "textquery",
            "locationbias": f"circle:5000@{latitude},{longitude}",
            "fields": "formatted_address,name,geometry",
            "key": PLACES_API_KEY,
        }
        url = "https://maps.googleapis.com/maps/api/place/findplacefromtext/json?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
        candidates = data.get("candidates") or []
        if not candidates:
            return None
        # 按与当前位置的距离排序，取最近的一个（避免 API 返回顺序不是按距离）
        def dist_key(c):
            geo = c.get("geometry") or {}
            loc = geo.get("location") or {}
            clat, clng = loc.get("lat"), loc.get("lng")
            if clat is None or clng is None:
                return float("inf")
            return _distance_km(latitude, longitude, clat, clng)
        candidates = sorted(candidates, key=dist_key)
        best = candidates[0]
        if best.get("formatted_address"):
            return best["formatted_address"]
    except Exception as e:
        print("Places resolve error:", e)
    return None


def resolve_waypoints(waypoints: list[str], latitude: float | None, longitude: float | None) -> list[str]:
    """对有「最近/附近」语义的站点，解析成具体一个地址；其余保持原样。"""
    if latitude is None or longitude is None:
        return waypoints
    out = []
    for w in waypoints:
        resolved = resolve_to_single_place(w, latitude, longitude)
        out.append(resolved if resolved else w)
    return out


@app.route("/plan", methods=["POST"])
def plan():
    """POST body: { "userInput": "去学校接孩子然后去麦当劳再回家", "latitude": 49.28, "longitude": -123.12 }"""
    if not GEMINI_API_KEY:
        return jsonify({"error": "GEMINI_API_KEY not configured"}), 500

    data = request.get_json(force=True, silent=True) or {}
    user_input = (data.get("userInput") or "").strip()
    latitude = data.get("latitude")
    longitude = data.get("longitude")

    if not user_input:
        return jsonify({"error": "userInput is required"}), 400

    try:
        waypoints = call_gemini(user_input, latitude, longitude)
        waypoints = resolve_waypoints(waypoints, latitude, longitude)
        return jsonify({"waypoints": waypoints})
    except Exception as e:
        traceback.print_exc()
        print("ERROR:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "gemini_configured": bool(GEMINI_API_KEY),
        "gemini_model": GEMINI_MODEL,
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5002))
    app.run(host="0.0.0.0", port=port, debug=True)
