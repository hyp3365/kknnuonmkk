const IPV6_LIST_URL='https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/CloudFlare-ipv6.txt';
const WS_SUB_PROTOCOL='grpc';

async function fetchIPv6List(){
    const response=await fetch(IPV6_LIST_URL,{headers:{'User-Agent':'Cloudflare-Worker'}});
    if(!response.ok)throw new Error(`IPv6 地址列表获取失败：HTTP ${response.status}`);
    const text=await response.text();
    const dateGroups={};
    for(const line of text.split(/\r?\n/)){
        const parts=line.trim().split(/\s+/);
        if(parts.length<2)continue;
        const date=parts[0];
        const ipv6=parts[parts.length-1];
        if(!/^\d{4}-\d{2}-\d{2}$/.test(date))continue;
        if(!ipv6.includes(':'))continue;
        if(!dateGroups[date])dateGroups[date]=[];
        if(!dateGroups[date].includes(ipv6))dateGroups[date].push(ipv6);
    }
    const dates=Object.keys(dateGroups);
    if(dates.length===0)throw new Error('IPv6 地址列表为空');
    dates.sort((a,b)=>b.localeCompare(a));
    const ipv6List=[];
    for(const date of dates){
        for(const ipv6 of dateGroups[date]){
            if(!ipv6List.includes(ipv6))ipv6List.push(ipv6);
            if(ipv6List.length>=30)return ipv6List;
        }
    }
    return ipv6List;
}

function base64Encode(text){
    const bytes=new TextEncoder().encode(text);
    let binary='';
    for(let i=0;i<bytes.length;i+=0x8000){
        binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));
    }
    return btoa(binary);
}

function encode(value){
    return encodeURIComponent(value);
}

function validateUUID(uuid){
    return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/.test(uuid);
}

function parseSubscriptionPath(pathname){
    const parts=pathname.split('/').filter(Boolean);
    if(parts.length!==4){
        throw new Error('订阅地址格式错误，应为：/UUID/xhttp/PATH/SNI、/UUID/vless/PATH/SNI 或 /UUID/vmess/PATH/SNI');
    }
    const uuid=decodeURIComponent(parts[0]);
    const type=decodeURIComponent(parts[1]).toLowerCase();
    const path='/'+decodeURIComponent(parts[2]);
    const sni=decodeURIComponent(parts[3]);
    if(!validateUUID(uuid))throw new Error('UUID 格式错误');
    if(type!=='xhttp'&&type!=='vless'&&type!=='vmess'){
        throw new Error('只支持 xhttp、vless 和 vmess');
    }
    if(!path||path==='/')throw new Error('PATH 不能为空');
    if(!sni)throw new Error('SNI 不能为空');
    return{uuid,type,path,sni};
}

function generateXhttpLink(uuid,ipv6,path,sni){
    const params=new URLSearchParams();
    params.set('encryption','none');
    params.set('security','tls');
    params.set('sni',sni);
    params.set('alpn','h3');
    params.set('type','xhttp');
    params.set('path',path);
    params.set('host',sni);
    return`vless://${uuid}@[${ipv6}]:443?${params.toString()}`;
}

function generateVlessWsLink(uuid,ipv6,path,sni){
    const params=new URLSearchParams();
    params.set('encryption','none');
    params.set('security','tls');
    params.set('sni',sni);
    params.set('type','ws');
    params.set('path',path);
    params.set('host',sni);
    params.set('max_early_data','2048');
    params.set('early_data_header_name','Sec-WebSocket-Protocol');
    return`vless://${uuid}@[${ipv6}]:443?${params.toString()}`;
}

function generateVmessWsLink(uuid,ipv6,path,sni){
    const config={
        v:"2",
        ps:`${sni}-${ipv6}`,
        add:ipv6,
        port:"443",
        id:uuid,
        aid:"0",
        scy:"auto",
        net:"ws",
        type:"none",
        host:sni,
        path:path,
        tls:"tls",
        sni:sni,
        alpn:"",
        fp:"",
        max_early_data:2048,
        early_data_header_name:"Sec-WebSocket-Protocol"
    };
    return`vmess://${base64Encode(JSON.stringify(config))}`;
}

async function generateSubscription(uuid,type,path,sni){
    const ipv6List=await fetchIPv6List();
    const result=[];
    for(const ipv6 of ipv6List){
        if(type==='xhttp'){
            result.push(generateXhttpLink(uuid,ipv6,path,sni));
        }else if(type==='vless'){
            result.push(generateVlessWsLink(uuid,ipv6,path,sni));
        }else if(type==='vmess'){
            result.push(generateVmessWsLink(uuid,ipv6,path,sni));
        }
    }
    return result.join('\n');
}

function htmlPage(message='',result=''){
    return`<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IPv6 动态订阅</title>
<style>
body{margin:0;padding:20px;background:#f5f5f5;font-family:Arial,sans-serif}
.container{max-width:700px;margin:40px auto;background:white;padding:25px;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08)}
h2{margin-top:0}
input{width:100%;box-sizing:border-box;padding:12px;margin-top:10px;border:1px solid #ccc;border-radius:8px;font-size:14px}
button{width:100%;margin-top:15px;padding:12px;border:0;border-radius:8px;background:#111;color:white;font-size:16px;cursor:pointer}
textarea{width:100%;box-sizing:border-box;margin-top:15px;padding:12px;border:1px solid #ccc;border-radius:8px;resize:vertical}
.result{height:100px}
.message{margin-top:15px;padding:10px;background:#f0f0f0;border-radius:6px;word-break:break-all}
</style>
</head>
<body>
<div class="container">
<h2>IPv6 动态订阅</h2>
<form method="POST">
<input name="uuid" placeholder="UUID" required>
<input name="type" placeholder="xhttp、vless 或 vmess" required>
<input name="path" placeholder="PATH，例如 sssisuiu" required>
<input name="sni" placeholder="SNI，例如 www.iij.ad.jp" required>
<button type="submit">生成订阅链接</button>
</form>
${result?`<textarea class="result" readonly onclick="this.select()">${escapeHtml(result)}</textarea>`:''}
</div>
</body>
</html>`;
}

function escapeHtml(text){
    return String(text)
        .replace(/&/g,'&amp;')
        .replace(/</g,'&lt;')
        .replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;')
        .replace(/'/g,'&#039;');
}

export default{
    async fetch(request){
        const url=new URL(request.url);
        if(request.method==='GET'&&url.pathname!=='/'){
            try{
                const config=parseSubscriptionPath(url.pathname);
                const result=await generateSubscription(
                    config.uuid,
                    config.type,
                    config.path,
                    config.sni
                );
                const encoded=base64Encode(result);
                return new Response(encoded,{
                    status:200,
                    headers:{
                        'Content-Type':'text/plain; charset=utf-8',
                        'Cache-Control':'no-store, no-cache, must-revalidate, max-age=0',
                        'Pragma':'no-cache',
                        'Access-Control-Allow-Origin':'*'
                    }
                });
            }catch(error){
                return new Response(
                    error.message||'订阅生成失败',
                    {
                        status:400,
                        headers:{
                            'Content-Type':'text/plain; charset=utf-8',
                            'Cache-Control':'no-store, no-cache, must-revalidate, max-age=0',
                            'Pragma':'no-cache',
                            'Access-Control-Allow-Origin':'*'
                        }
                    }
                );
            }
        }
        if(url.pathname!=='/')return new Response('Not Found',{status:404});
        if(request.method==='GET'){
            return new Response(htmlPage(),{
                headers:{
                    'Content-Type':'text/html; charset=utf-8'
                }
            });
        }
        if(request.method==='POST'){
            try{
                const form=await request.formData();
                const uuid=String(form.get('uuid')||'').trim();
                const type=String(form.get('type')||'').trim().toLowerCase();
                let path=String(form.get('path')||'').trim();
                const sni=String(form.get('sni')||'').trim();
                if(!path.startsWith('/'))path='/'+path;
                const pathname=
                    `/${encodeURIComponent(uuid)}`+
                    `/${encodeURIComponent(type)}`+
                    `/${encodeURIComponent(path.slice(1))}`+
                    `/${encodeURIComponent(sni)}`;
                parseSubscriptionPath(pathname);
                const subscriptionUrl=`${url.origin}${pathname}`;
                return new Response(
                    htmlPage('',subscriptionUrl),
                    {
                        headers:{
                            'Content-Type':'text/html; charset=utf-8'
                        }
                    }
                );
            }catch(error){
                return new Response(
                    htmlPage('',error.message||'生成失败'),
                    {
                        status:400,
                        headers:{
                            'Content-Type':'text/html; charset=utf-8'
                        }
                    }
                );
            }
        }
        return new Response('Method Not Allowed',{status:405});
    }
};
