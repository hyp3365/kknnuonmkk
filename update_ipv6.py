import ipaddress
import re
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path


SOURCES = {
    "https://www.wetest.vip/page/cloudfront/total_v6.html": "CloudFront-ipv6.txt",
    "https://www.wetest.vip/page/cloudflare/total_v6.html": "CloudFlare-ipv6.txt",
}


IPV6_PATTERN = re.compile(
    r'(?<![0-9A-Fa-f:])'
    r'(?:[0-9A-Fa-f]{1,4}:){2,7}'
    r'[0-9A-Fa-f]{0,4}'
    r'(?![0-9A-Fa-f:])'
)


def fetch_ipv6(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0"
        }
    )

    with urllib.request.urlopen(req, timeout=30) as response:
        html = response.read().decode(
            "utf-8",
            errors="ignore"
        )

    matches = IPV6_PATTERN.findall(html)

    ipv6_list = []

    for item in matches:
        try:
            ip = ipaddress.IPv6Address(item)
            ipv6_list.append(str(ip))
        except ValueError:
            continue

    return ipv6_list


def update_file(filename, ipv6_list, today):
    path = Path.cwd() / filename

    cutoff = today - timedelta(days=29)

    old_lines = []

    if path.exists():
        old_lines = path.read_text(
            encoding="utf-8"
        ).splitlines()

    new_lines = []

    # 保留最近30天
    for line in old_lines:
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

        if record_date >= cutoff:
            new_lines.append(line)

    # 今天的数据全部追加
    for ip in ipv6_list:
        new_lines.append(
            f"{today} {ip}"
        )

    path.write_text(
        "\n".join(new_lines) + "\n",
        encoding="utf-8"
    )

    print(f"保存文件: {path}")
    print(f"今天 IPv6: {len(ipv6_list)}")
    print(f"当前记录: {len(new_lines)}")


def main():
    today = datetime.utcnow().date()

    print(f"今天日期: {today}")
    print(f"工作目录: {Path.cwd()}")

    for url, filename in SOURCES.items():

        print()
        print("=" * 60)
        print(f"访问: {url}")
        print(f"文件: {filename}")

        try:
            ipv6_list = fetch_ipv6(url)

            if not ipv6_list:
                print("没有获取到 IPv6，跳过")
                continue

            update_file(
                filename,
                ipv6_list,
                today
            )

        except Exception as e:
            print(f"获取失败: {e}")


if __name__ == "__main__":
    main()
