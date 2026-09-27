import re
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SITES = {
    "https://www.wetest.vip/page/cloudfront/total_v6.html": "CloudFront-ipv6.txt",
    "https://www.wetest.vip/page/cloudflare/total_v6.html": "CloudFlare-ipv6.txt",
}

CST = timezone(timedelta(hours=8))
today = datetime.now(CST).date()
today_str = today.strftime("%Y-%m-%d")

for url, filename in SITES.items():
    print("=" * 70)
    print(f"网站：{url}")
    print(f"文件：{filename}")

    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0"}
        )

        html = urllib.request.urlopen(req, timeout=30).read().decode(
            "utf-8", errors="ignore"
        )

        # 只提取表格第一列的 IPv6
        ipv6_list = re.findall(
            r'<tr[^>]*>\s*<td[^>]*>\s*([0-9a-fA-F:]+)\s*</td>',
            html,
            re.I
        )

        # 如果网站使用 Markdown 表格格式，使用这个方式
        if not ipv6_list:
            ipv6_list = re.findall(
                r'^\|([0-9a-fA-F]*:[0-9a-fA-F:]+)\|',
                html,
                re.MULTILINE
            )

        # 只取前15个
        ipv6_list = ipv6_list[:15]

        print(f"提取 IPv6：{len(ipv6_list)}")

        if not ipv6_list:
            print("没有找到 IPv6，跳过")
            continue

        file = Path(filename)

        # 旧数据
        old_lines = []
        if file.exists():
            old_lines = file.read_text(
                encoding="utf-8"
            ).splitlines()

        # 今天的数据
        new_lines = [
            f"{today_str} {ip}"
            for ip in ipv6_list
        ]

        # 合并，不去重
        all_lines = old_lines + new_lines

        # 最近30天
        cutoff = today - timedelta(days=29)

        result = []

        for line in all_lines:
            parts = line.split(maxsplit=1)

            if len(parts) != 2:
                continue

            try:
                date = datetime.strptime(
                    parts[0],
                    "%Y-%m-%d"
                ).date()
            except ValueError:
                continue

            if cutoff <= date <= today:
                result.append(line)

        file.write_text(
            "\n".join(result) + "\n",
            encoding="utf-8"
        )

        print("今日 IPv6：")
        for ip in ipv6_list:
            print(f"{today_str} {ip}")

        print(f"保存完成：{filename}")

    except Exception as e:
        print(f"获取失败：{e}")
