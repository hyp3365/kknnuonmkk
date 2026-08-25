#!/bin/bash

set -e

APP_DIR="/opt/tgvideo"

echo "=== Telegram 视频系统安装 ==="


#################################
# 1. 安装系统依赖
#################################

echo "安装系统依赖..."

apt update -y

apt install -y \
python3 \
python3-venv \
python3-pip


#################################
# 2. 创建目录
#################################

echo "创建目录..."

mkdir -p $APP_DIR

cd $APP_DIR



#################################
# 3. 写入 requirements.txt
#################################

cat > requirements.txt <<'EOF'
fastapi
uvicorn
telethon
EOF



#################################
# 4. 写入 config.py
#################################

cat > config.py <<'EOF'
api_id = 0
api_hash = ""
EOF



#################################
# 5. 写入 login.py
#################################

cat > login.py <<'EOF'
from telethon import TelegramClient
from config import api_id, api_hash


client = TelegramClient(
    "session",
    api_id,
    api_hash
)


async def main():

    phone = input(
        "请输入手机号(带国家区号，例如 +8613812345678): "
    )

    await client.start(
        phone=phone
    )

    print("登录成功")

    await client.disconnect()


with client:
    client.loop.run_until_complete(main())
EOF



#################################
# 6. 写入 app.py
#################################

cd /opt/tgvideo
cp app.py app.old
cat > app.py <<'EOF'
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse, HTMLResponse, Response, JSONResponse
from telethon import TelegramClient
from telethon.tl.types import Channel
from config import api_id, api_hash
app = FastAPI()
client = TelegramClient(
    "session",
    api_id,
    api_hash
)
@app.on_event("startup")
async def startup():
    await client.connect()
    print("Telegram connected")
@app.get("/")
async def index():
    return HTMLResponse("""
    <h2>Telegram 视频</h2>
    <a href="/channels">
    频道列表
    </a>
    """)
@app.get("/channels")
async def channels():
    html="""
    <h2>我的频道</h2>
    """
    async for dialog in client.iter_dialogs():
        if isinstance(dialog.entity, Channel):
            html += f"""
            <p>
            <a href="/channel/{dialog.id}">
            {dialog.name}
            </a>
            </p>
            """
    return HTMLResponse(html)
@app.get("/channel/{channel_id}")
async def channel(
    channel_id:int,
    offset:int=0
):
    videos_html=""

    async for msg in client.iter_messages(
        channel_id,
        limit=30,
        offset_id=offset
    ):
        if msg.video and msg.video.thumbs:
            name = ""

            if msg.message:
                name = msg.message[:60]
            elif msg.file and msg.file.name:
                name = msg.file.name
            else:
                name = f"视频 {msg.id}"

            videos_html += f"""
            <div class="item">

            <img
            onclick="playVideo('/video/{channel_id}/{msg.id}')"
            src="/thumb/{channel_id}/{msg.id}">

            <div class="name">
            {name}
            </div>

            </div>
            """
    html=f"""
<!DOCTYPE html>
<html>
<head>
<meta name="viewport"
content="width=device-width,initial-scale=1">
<style>
body{{
margin:10px;
font-family:Arial;
}}
.grid{{
display:grid;
grid-template-columns:
repeat(3,1fr);
gap:10px;
}}
.item img{{
width:100%;
aspect-ratio:16/9;
object-fit:cover;
border-radius:8px;
}}
.name{{
font-size:14px;
word-break:break-all;
}}
.player{{
display:none;
position:fixed;
top:0;
left:0;
width:100%;
height:100%;
background:#000;
z-index:999;
}}
.player video{{
width:100%;
margin-top:20%;
}}
.close{{
color:white;
font-size:30px;
padding:10px;
}}
</style>
</head>
<body>
<h3>
视频
</h3>
<div class="grid">
{videos_html}
</div>
<div style="display:flex;justify-content:space-between;margin:20px">

<a href="/channel/{channel_id}?offset={max(offset-30,0)}">
<button>
上一页
</button>
</a>


<a href="/channel/{channel_id}?offset={offset+30}">
<button>
下一页
</button>
</a>

</div>
<div id="loading">
加载中...
</div>
<div id="player"
class="player">
<div class="close"
onclick="closePlayer()">
×
</div>
<video id="video"
controls
autoplay>
</video>
</div>
<script>
function playVideo(url){{
let box=document
.getElementById("player");
let video=document
.getElementById("video");
video.src=url;
box.style.display="block";
video.play();
}}

function closePlayer(){{
let video=document
.getElementById("video");
video.pause();
video.src="";
document
.getElementById("player")
.style.display="none";
}}
</script>
</body>
</html>
"""
    return HTMLResponse(html)
@app.get("/api/videos/{channel_id}")
async def api_videos(
    channel_id:int,
    offset:int=0
):
    html=""
    count=0
    last_id=offset
    async for msg in client.iter_messages(
        channel_id,
        limit=30,
        offset_id=offset
    ):
        last_id=msg.id
        if msg.video and msg.video.thumbs:
            count+=1
            name=""
            if msg.message:
                name=msg.message[:60]
            elif msg.file and msg.file.name:
                name=msg.file.name
            else:
                name=f"视频 {msg.id}"
            html+=f"""
<div class="item">
<img loading="lazy"
onclick="playVideo('/video/{channel_id}/{msg.id}')"
src="/thumb/{channel_id}/{msg.id}">
<div class="name">
{name}
</div>
</div>
"""
    return JSONResponse({
        "html": html,
        "next_offset": last_id,
        "has_more": count >= 30
    })
@app.get("/thumb/{channel_id}/{msg_id}")
async def thumb(
    channel_id:int,
    msg_id:int
):
    msg = await client.get_messages(
        channel_id,
        ids=msg_id
    )

    if not msg:
        raise HTTPException(404)

    data = None

    # 优先取视频缩略图
    if msg.video and msg.video.thumbs:
        data = await client.download_media(
            msg,
            file=bytes,
            thumb=-1
        )

    # 没有缩略图，用视频第一帧
    if not data:
        data = await client.download_media(
            msg,
            file=bytes
        )

    if not data:
        raise HTTPException(404)

    return Response(
        content=data,
        media_type="image/jpeg"
    )
    msg = await client.get_messages(
        channel_id,
        ids=msg_id
    )
    if not msg:
        raise HTTPException(404)
    data = await client.download_media(
        msg,
        file=bytes,
        thumb=1
    )
    if not data:
        raise HTTPException(404)
    return Response(
        content=data,
        media_type="image/jpeg"
    )
@app.get("/video/{channel_id}/{msg_id}")
async def video(
    request:Request,
    channel_id:int,
    msg_id:int
):
    msg = await client.get_messages(
        channel_id,
        ids=msg_id
    )
    if not msg or not msg.file:
        raise HTTPException(404)
    file_size = msg.file.size
    range_header = request.headers.get(
        "range"
    )
    start = 0
    end = file_size - 1
    if range_header:
        value = range_header.replace(
            "bytes=",
            ""
        )
        parts=value.split("-")
        start=int(parts[0])
        if len(parts)>1 and parts[1]:
            end=int(parts[1])
    length=end-start+1
    async def stream():
        remaining=length
        async for chunk in client.iter_download(
            msg.media,
            offset=start,
            request_size=1024*1024
        ):
            if remaining<=0:
                break
            if len(chunk)>remaining:
                chunk=chunk[:remaining]
            remaining-=len(chunk)
            yield chunk
    headers={
        "Accept-Ranges":"bytes",
        "Content-Length":str(length),
        "Content-Range":
        f"bytes {start}-{end}/{file_size}"
    }
    return StreamingResponse(
        stream(),
        status_code=206 if range_header else 200,
        headers=headers,
        media_type="video/mp4"
    )
EOF



#################################
# 7. 创建 Python 环境
#################################

echo "创建虚拟环境..."

python3 -m venv venv


source venv/bin/activate



#################################
# 8. 安装 Python 库
#################################

pip install --upgrade pip

pip install -r requirements.txt



#################################
# 9. 设置 Telegram
#################################

echo

read -p "输入 Telegram api_id: " TG_ID

read -p "输入 Telegram api_hash: " TG_HASH


cat > config.py <<EOF
api_id = $TG_ID
api_hash = "$TG_HASH"
EOF



#################################
# 10. 登录 Telegram
#################################

echo "开始登录 Telegram"

python login.py



#################################
# 11. 创建启动服务
#################################

cat >/etc/systemd/system/tgvideo.service <<EOF
[Unit]
Description=Telegram Video
After=network.target

[Service]
WorkingDirectory=/opt/tgvideo
ExecStart=/opt/tgvideo/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF



#################################
# 12. 启动
#################################

systemctl daemon-reload

systemctl enable tgvideo

systemctl restart tgvideo



echo
echo "=========================="
echo "安装完成"
echo "访问:"
echo "http://服务器IP:8000"
echo "=========================="
