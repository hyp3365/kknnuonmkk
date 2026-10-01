import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SITES = {
    "https://www.wetest.vip/page/cloudfront/total_v6.html": "CloudFront-ipv6.txt",
    "https://www.wetest.vip/page/cloudflare/total_v6.html": "CloudFlare-ipv6.txt",
}

OUTPUT_DIR = Path("ipv6")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

CST = timezone(timedelta(hours=8))
today = datetime.now(CST).date()
today_str = today.strftime("%Y-%m-%d")


def get_ipv6(url):
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

    result = []

    # 从统计优选列表后面找 IPv6
    for line in lines[start + 1:]:
        # 第一列就是 IPv6
        if ":" in line and "|" not in line:
            parts = line.split()

            if parts and ":" in parts[0]:
                ip = parts[0]

                # IPv6 至少包含两个 :
                if ip.count(":") >= 2:
                    result.append(ip)

        if len(result) == 15:
            break

    return result


for url, filename in SITES.items():

    print("=" * 70)
    print(f"网站：{url}")
    print(f"文件：{filename}")
    print("=" * 70)

    try:
        ipv6_list = get_ipv6(url)

        print(f"提取 IPv6：{len(ipv6_list)}")

        if len(ipv6_list) != 15:
            print("没有正确获取到15个 IPv6，跳过本次更新")
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
            for ip in ipv6_list
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

        for ip in ipv6_list:
            print(f"{today_str} {ip}")

        print()
        print(f"保存完成：{filename}")

    except Exception as e:
        print(f"获取失败：{e}")
