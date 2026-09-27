import re
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SITES = {
    "https://www.wetest.vip/page/cloudfront/total_v6.html": "CloudFront-ipv6.txt",
    "https://www.wetest.vip/page/cloudflare/total_v6.html": "CloudFlare-ipv6.txt",
}

# 北京时间
CST = timezone(timedelta(hours=8))
today = datetime.now(CST).date()
today_str = today.strftime("%Y-%m-%d")

print("=" * 70)
print("IPv6 自动采集")
print("=" * 70)
print(f"日期：{today_str}")

for url, filename in SITES.items():
    print()
    print("=" * 70)
    print(f"网站：{url}")
    print(f"文件：{filename}")
    print("=" * 70)

    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0"}
        )

        with urllib.request.urlopen(req, timeout=30) as response:
            html = response.read().decode("utf-8", errors="ignore")

        # 提取每一行 | 前面的 IPv6
        ipv6_list = re.findall(
            r'^\s*(?:\|?\s*)([0-9a-fA-F:]*:[0-9a-fA-F:]+)\s*\|',
            html,
            re.MULTILINE
        )

        print(f"网页大小：{len(html)} bytes")
        print(f"提取 IPv6：{len(ipv6_list)}")

        if not ipv6_list:
            print("没有找到 IPv6，跳过本次更新")
            continue

        file = Path(filename)

        # 读取旧记录
        old_lines = []
        if file.exists():
            old_lines = file.read_text(encoding="utf-8").splitlines()

        # 添加今天的数据
        new_lines = [
            f"{today_str} {ip}"
            for ip in ipv6_list
        ]

        all_lines = old_lines + new_lines

        # 只保留最近30天
        cutoff = today - timedelta(days=29)

        result = []

        for line in all_lines:
            parts = line.split(maxsplit=1)

            if len(parts) != 2:
                continue

            try:
                record_date = datetime.strptime(
                    parts[0], "%Y-%m-%d"
                ).date()
            except ValueError:
                continue

            if cutoff <= record_date <= today:
                result.append(line)

        file.write_text(
            "\n".join(result) + "\n",
            encoding="utf-8"
        )

        print(f"写入：{len(new_lines)} 条")
        print(f"保留：{len(result)} 条")
        print(f"文件：{file}")

    except Exception as e:
        print(f"获取失败：{e}")

print()
print("=" * 70)
print("更新完成")
print("=" * 70)
