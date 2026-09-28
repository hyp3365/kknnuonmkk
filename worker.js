#节点优选ipv6地址

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
    const ipv6List = [];

    for (const line of text.split(/\r?\n/)) {
        const parts = line.trim().split(/\s+/);

        if (parts.length < 2) {
            continue;
        }

        const ipv6 = parts[parts.length - 1];

        if (!ipv6.includes(':')) {
            continue;
        }

        if (!ipv6List.includes(ipv6)) {
            ipv6List.push(ipv6);
        }
    }

    if (ipv6List.length === 0) {
        throw new Error('IPv6 地址列表为空');
    }

    return ipv6List;
}

function decodeBase64(text) {
    try {
        const binary = atob(text.replace(/\s/g, ''));
        const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
        return new TextDecoder().decode(bytes);
    } catch {
        return '';
    }
}

function extractLinks(input) {
    input = input.trim();

    let links = input
        .split(/\r?\n/)
        .map(line => line.trim())
        .filter(line => line.startsWith('vmess://') || line.startsWith('vless://'));

    if (links.length > 0) {
        return links;
    }

    const decoded = decodeBase64(input);

    if (decoded) {
        links = decoded
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(line => line.startsWith('vmess://') || line.startsWith('vless://'));

        if (links.length > 0) {
            return links;
        }
    }

    throw new Error('没有找到有效的 VMess 或 VLESS 连接');
}

function replaceServerAddress(connection, ipv6) {
    const match = connection.match(/^(vmess|vless):\/\/([^@]+)@([^:/]+|\[[^\]]+\])(:\d+)(.*)$/);

    if (!match) {
        throw new Error('连接格式错误');
    }

    const protocol = match[1];
    const userInfo = match[2];
    const port = match[4];
    const rest = match[5];

    return `${protocol}://${userInfo}@[${ipv6}]${port}${rest}`;
}

function base64Encode(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';

    for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }

    return btoa(binary);
}

async function generateSubscription(input) {
    const links = extractLinks(input);
    const ipv6List = await fetchIPv6List();
    const result = [];

    for (const link of links) {
        for (const ipv6 of ipv6List) {
            result.push(replaceServerAddress(link, ipv6));
        }
    }

    return result.join('\n');
}

function htmlPage(message = '', result = '') {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>生成</title>
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
<h2>生成</h2>
<form method="POST">
<textarea name="subscription" placeholder="输入 VMess / VLESS 订阅连接">${escapeHtml(message)}</textarea>
<button type="submit">生成</button>
</form>
${result ? `<textarea class="result" readonly>${escapeHtml(result)}</textarea>` : ''}
</div>
</body>
</html>`;
}

function escapeHtml(text) {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

export default {
    async fetch(request) {
        const url = new URL(request.url);

        if (url.pathname !== '/') {
            return new Response('Not Found', {
                status: 404
            });
        }

        if (request.method === 'GET') {
            return new Response(htmlPage(), {
                headers: {
                    'Content-Type': 'text/html; charset=utf-8'
                }
            });
        }

        if (request.method === 'POST') {
            try {
                const form = await request.formData();
                const subscription = String(form.get('subscription') || '').trim();

                if (!subscription) {
                    return new Response(htmlPage('请输入 VMess 或 VLESS 订阅连接'), {
                        headers: {
                            'Content-Type': 'text/html; charset=utf-8'
                        }
                    });
                }

                const result = await generateSubscription(subscription);

                return new Response(htmlPage('', result), {
                    headers: {
                        'Content-Type': 'text/html; charset=utf-8'
                    }
                });
            } catch (error) {
                return new Response(htmlPage(error.message || '生成失败'), {
                    status: 400,
                    headers: {
                        'Content-Type': 'text/html; charset=utf-8'
                    }
                });
            }
        }

        return new Response('Method Not Allowed', {
            status: 405
        });
    }
};
