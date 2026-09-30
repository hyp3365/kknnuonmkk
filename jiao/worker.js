const IPV6_LIST_URL = 'https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/CloudFlare-ipv6.txt';

async function fetchIPv6List() {
    const response = await fetch(IPV6_LIST_URL, {
        headers: {
            'User-Agent': 'Cloudflare-Worker'
        }
    });

    if (!response.ok) {
        throw new Error(`IPv6 地址列表获取失败：HTTP ${response.status}`);
    }

    const text = await response.text();
    const dateGroups = {};

    for (const line of text.split(/\r?\n/)) {
        const parts = line.trim().split(/\s+/);

        if (parts.length < 2) {
            continue;
        }

        const date = parts[0];
        const ipv6 = parts[parts.length - 1];

        if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
            continue;
        }

        if (!ipv6.includes(':')) {
            continue;
        }

        if (!dateGroups[date]) {
            dateGroups[date] = [];
        }

        if (!dateGroups[date].includes(ipv6)) {
            dateGroups[date].push(ipv6);
        }
    }

    const dates = Object.keys(dateGroups);

    if (dates.length === 0) {
        throw new Error('IPv6 地址列表为空');
    }

    dates.sort((a, b) => b.localeCompare(a));

    const ipv6List = [];

    for (const date of dates) {
        for (const ipv6 of dateGroups[date]) {
            if (!ipv6List.includes(ipv6)) {
                ipv6List.push(ipv6);
            }

            if (ipv6List.length >= 30) {
                return ipv6List;
            }
        }
    }

    return ipv6List;
}


// ==================== Base64 解码 ====================

function decodeBase64(text) {
    try {
        let normalized = text
            .replace(/\s/g, '')
            .replace(/-/g, '+')
            .replace(/_/g, '/');

        while (normalized.length % 4 !== 0) {
            normalized += '=';
        }

        const binary = atob(normalized);

        const bytes = Uint8Array.from(
            binary,
            c => c.charCodeAt(0)
        );

        return new TextDecoder().decode(bytes);
    } catch {
        return '';
    }
}


// ==================== Base64 编码 ====================

function base64Encode(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';

    for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode(
            ...bytes.subarray(i, i + 0x8000)
        );
    }

    return btoa(binary);
}


// ==================== Base64URL 编码 ====================
// 用于把用户输入放进 /sub?data=xxxxx

function base64UrlEncode(text) {
    return base64Encode(text)
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, '');
}


// ==================== Base64URL 解码 ====================

function base64UrlDecode(text) {
    try {
        let normalized = text
            .replace(/-/g, '+')
            .replace(/_/g, '/');

        while (normalized.length % 4 !== 0) {
            normalized += '=';
        }

        return decodeBase64(normalized);
    } catch {
        return '';
    }
}


// ==================== 提取 VMess / VLESS ====================

function extractLinks(input) {
    input = input.trim();

    let links = input
        .split(/\r?\n/)
        .map(line => line.trim())
        .filter(line =>
            line.startsWith('vmess://') ||
            line.startsWith('vless://')
        );

    if (links.length > 0) {
        return links;
    }

    const decoded = decodeBase64(input);

    if (decoded) {
        links = decoded
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(line =>
                line.startsWith('vmess://') ||
                line.startsWith('vless://')
            );

        if (links.length > 0) {
            return links;
        }
    }

    throw new Error('没有找到有效的 VMess 或 VLESS 连接');
}


// ==================== 替换服务器 IPv6 ====================

function replaceServerAddress(connection, ipv6) {
    const match = connection.match(
        /^(vmess|vless):\/\/([^@]+)@([^:/]+|\[[^\]]+\])(:\d+)(.*)$/
    );

    if (!match) {
        throw new Error('连接格式错误');
    }

    const protocol = match[1];
    const userInfo = match[2];
    const port = match[4];
    const rest = match[5];

    return `${protocol}://${userInfo}@[${ipv6}]${port}${rest}`;
}


// ==================== 生成 IPv6 节点 ====================

async function generateSubscription(input) {
    const links = extractLinks(input);
    const ipv6List = await fetchIPv6List();

    const result = [];

    for (const link of links) {
        for (const ipv6 of ipv6List) {
            result.push(
                replaceServerAddress(link, ipv6)
            );
        }
    }

    return result.join('\n');
}


// ==================== HTML ====================

function htmlPage(message = '', result = '') {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IPV6优选</title>
<style>
body {
    margin: 0;
    padding: 20px;
    background: #f5f5f5;
    font-family: Arial,sans-serif;
}
.container {
    max-width: 700px;
    margin: 40px auto;
    background: white;
    padding: 25px;
    border-radius: 12px;
    box-shadow: 0 2px 12px rgba(0,0,0,.08);
}
h2 {
    margin-top: 0;
}
textarea {
    width: 100%;
    height: 180px;
    box-sizing: border-box;
    padding: 12px;
    border: 1px solid #ccc;
    border-radius: 8px;
    resize: vertical;
    font-size: 14px;
}
button {
    width: 100%;
    margin-top: 15px;
    padding: 12px;
    border: 0;
    border-radius: 8px;
    background: #111;
    color: white;
    font-size: 16px;
    cursor: pointer;
}
button:hover {
    opacity: .85;
}
.message {
    margin-top: 15px;
    padding: 10px;
    border-radius: 6px;
    background: #f0f0f0;
    word-break: break-all;
}
.result {
    margin-top: 15px;
    height: 120px;
}
</style>
</head>

<body>

<div class="container">

<h2>IPV6优选</h2>

<form method="POST">

<textarea
    name="subscription"
    placeholder="输入 VMess / VLESS 订阅连接"
>${escapeHtml(message)}</textarea>

<button type="submit">
生成IPV6优选连接
</button>

</form>

${result ? `
<textarea
    class="result"
    readonly
    onclick="this.select()"
>${escapeHtml(result)}</textarea>
` : ''}

</div>

</body>
</html>`;
}


// ==================== HTML 转义 ====================

function escapeHtml(text) {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}


// ==================== Worker ====================

export default {

    async fetch(request) {

        const url = new URL(request.url);


        // ==================================================
        // 动态订阅接口
        //
        // 客户端每次更新：
        //
        // /sub?data=xxxxxxxx
        //
        // 都会重新获取最新 IPv6 列表
        // ==================================================

        if (url.pathname === '/sub') {

            if (request.method !== 'GET') {
                return new Response('Method Not Allowed', {
                    status: 405
                });
            }

            try {

                const data = url.searchParams.get('data');

                if (!data) {
                    return new Response(
                        'Missing subscription data',
                        {
                            status: 400,
                            headers: {
                                'Content-Type': 'text/plain; charset=utf-8'
                            }
                        }
                    );
                }


                // 还原用户最开始提交的内容
                const originalInput = base64UrlDecode(data);

                if (!originalInput) {
                    return new Response(
                        '订阅数据解析失败',
                        {
                            status: 400,
                            headers: {
                                'Content-Type': 'text/plain; charset=utf-8'
                            }
                        }
                    );
                }


                // 每次访问都重新生成
                // 因此客户端每次更新订阅都会获取最新 IPv6
                const result = await generateSubscription(
                    originalInput
                );


                // 返回标准 Base64 订阅
                const encodedResult = base64Encode(result);


                return new Response(
                    encodedResult,
                    {
                        status: 200,
                        headers: {
                            'Content-Type': 'text/plain; charset=utf-8',

                            // 防止中间缓存旧节点
                            'Cache-Control':
                                'no-store, no-cache, must-revalidate, max-age=0',

                            'Pragma': 'no-cache',

                            // 允许客户端跨域读取
                            'Access-Control-Allow-Origin': '*'
                        }
                    }
                );

            } catch (error) {

                return new Response(
                    error.message || '订阅生成失败',
                    {
                        status: 400,
                        headers: {
                            'Content-Type':
                                'text/plain; charset=utf-8',

                            'Cache-Control':
                                'no-store, no-cache, must-revalidate, max-age=0',

                            'Access-Control-Allow-Origin': '*'
                        }
                    }
                );
            }
        }


        // ==================================================
        // 原来的首页
        // ==================================================

        if (url.pathname !== '/') {
            return new Response('Not Found', {
                status: 404
            });
        }


        // ==================================================
        // GET
        // ==================================================

        if (request.method === 'GET') {

            return new Response(
                htmlPage(),
                {
                    headers: {
                        'Content-Type':
                            'text/html; charset=utf-8'
                    }
                }
            );
        }


        // ==================================================
        // POST
        // ==================================================

        if (request.method === 'POST') {

            try {

                const form = await request.formData();

                const subscription =
                    String(
                        form.get('subscription') || ''
                    ).trim();


                if (!subscription) {

                    return new Response(
                        htmlPage(
                            '请输入 VMess 或 VLESS 订阅连接'
                        ),
                        {
                            headers: {
                                'Content-Type':
                                    'text/html; charset=utf-8'
                            }
                        }
                    );
                }


                // ==================================================
                // 这里不再生成 IPv6 节点
                //
                // 只验证输入是否有效
                // ==================================================

                extractLinks(subscription);


                // ==================================================
                // 把用户输入编码进动态订阅 URL
                // ==================================================

                const data =
                    base64UrlEncode(subscription);


                const subscriptionUrl =
                    `${url.origin}/sub?data=${data}`;


                // 页面显示动态订阅链接
                return new Response(
                    htmlPage('', subscriptionUrl),
                    {
                        headers: {
                            'Content-Type':
                                'text/html; charset=utf-8'
                        }
                    }
                );

            } catch (error) {

                return new Response(
                    htmlPage(
                        error.message || '生成失败'
                    ),
                    {
                        status: 400,
                        headers: {
                            'Content-Type':
                                'text/html; charset=utf-8'
                        }
                    }
                );
            }
        }


        return new Response(
            'Method Not Allowed',
            {
                status: 405
            }
        );
    }
};
