import urllib.request
import ipaddress
from datetime import datetime, timedelta, timezone
from pathlib import Path

SITES = {
    "https://www.wetest.vip/page/cloudfront/total_v4.html": "CloudFront-ipv4.txt",
    "https://www.wetest.vip/page/cloudfront/total_v6.html": "CloudFront-ipv6.txt",
    "https://www.wetest.vip/page/cloudflare/total_v4.html": "CloudFlare-ipv4.txt",
    "https://www.wetest.vip/page/cloudflare/total_v6.html": "CloudFlare-ipv6.txt",
}

OUTPUT_DIR = Path("ipv6")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

CST = timezone(timedelta(hours=8))
today = datetime.now(CST).date()
today_str = today.strftime("%Y-%m-%d")


def get_ip(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0"
        }
    )

    html = urllib.request.urlopen(req, timeout=30).read().decode(
        "utf-8",
        errors="ignore"
    )

    # 转成网页文本
    from html.parser import HTMLParser

    class Parser(HTMLParser):
        def __init__(self):
            super().__init__()
            self.text = []

        def handle_data(self, data):
            self.text.append(data)

    parser = Parser()
    parser.feed(html)

    lines = [
        x.strip()
        for x in parser.text
        if x.strip()
    ]

    # 找到“统计优选列表”
    start = -1

    for i, line in enumerate(lines):
        if "统计优选列表" in line:
            start = i
            break

    if start == -1:
        return []

    # 根据 URL 判断 IPv4 / IPv6
    is_ipv6 = "_v6" in url

    result = []

    # 从统计优选列表后面找 IP
    for line in lines[start + 1:]:
        parts = line.split()

        if not parts:
            continue

        ip = parts[0]

        try:
            addr = ipaddress.ip_address(ip)

            if is_ipv6 and addr.version == 6:
                result.append(ip)

            elif not is_ipv6 and addr.version == 4:
                result.append(ip)

        except ValueError:
            continue

        if len(result) == 15:
            break

    return result


for url, filename in SITES.items():

    print("=" * 70)
    print(f"网站：{url}")
    print(f"文件：{filename}")
    print("=" * 70)

    try:
        ip_list = get_ip(url)

        print(f"提取 IP：{len(ip_list)}")

        if len(ip_list) != 15:
            print("没有正确获取到15个 IP，跳过本次更新")
            continue

        file = OUTPUT_DIR / filename

        old_lines = []

        if file.exists():
            old_lines = file.read_text(
                encoding="utf-8"
            ).splitlines()

        # 今天追加15个
        new_lines = [
            f"{today_str} {ip}"
            for ip in ip_list
        ]

        all_lines = old_lines + new_lines

        # 保留最近30天
        cutoff = today - timedelta(days=29)

        result = []

        for line in all_lines:
            parts = line.split(maxsplit=1)

            if len(parts) != 2:
                continue

            try:
                record_date = datetime.strptime(
                    parts[0],
                    "%Y-%m-%d"
                ).date()
            except ValueError:
                continue

            if cutoff <= record_date <= today:
                result.append(line)

        file.write_text(
            "\n".join(result) + "\n",
            encoding="utf-8"
        )

        print()
        print("本次获取：")

        for ip in ip_list:
            print(f"{today_str} {ip}")

        print()
        print(f"保存完成：{file}")

    except Exception as e:
        print(f"获取失败：{e}")
