import ipaddress
import re
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


SOURCES = {
    "https://www.wetest.vip/page/cloudfront/total_v6.html":
        "CloudFront-ipv6.txt",

    "https://www.wetest.vip/page/cloudflare/total_v6.html":
        "CloudFlare-ipv6.txt",
}


def fetch_page(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 "
                "(KHTML, like Gecko) "
                "Chrome/140.0 Safari/537.36"
            )
        }
    )

    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read()

    return data.decode("utf-8", errors="ignore")


def extract_ipv6(html):
    # 从网页中寻找可能的 IPv6
    pattern = re.compile(
        r'(?<![0-9A-Fa-f:])'
        r'(?:[0-9A-Fa-f]{1,4}:){2,7}'
        r'(?:[0-9A-Fa-f]{1,4})?'
        r'(?![0-9A-Fa-f:])'
    )

    matches = pattern.findall(html)

    result = []

    for item in matches:
        try:
            ip = ipaddress.IPv6Address(item)
            result.append(str(ip))
        except ValueError:
            continue

    return result


def update_file(filename, ipv6_list, today):
    path = Path(filename)

    # 今天 + 前29天 = 30天
    cutoff = today - timedelta(days=29)

    old_lines = []

    if path.exists():
        old_lines = path.read_text(
            encoding="utf-8"
        ).splitlines()

    new_lines = []

    # 保留30天以内的历史记录
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

    # 不去重，全部保存
    for ip in ipv6_list:
        new_lines.append(
            f"{today} {ip}"
        )

    path.write_text(
        "\n".join(new_lines) + "\n",
        encoding="utf-8"
    )

    print()
    print(f"文件：{filename}")
    print(f"今天获取：{len(ipv6_list)} 个 IPv6")
    print(f"当前总记录：{len(new_lines)}")
    print(f"保存位置：{path}")


def main():

    # 使用北京时间
    today = datetime.now(
        timezone(timedelta(hours=8))
    ).date()

    print("========================================")
    print("IPv6 自动更新")
    print(f"北京时间日期：{today}")
    print(f"工作目录：{Path.cwd()}")
    print("========================================")

    success = 0

    for url, filename in SOURCES.items():

        print()
        print("----------------------------------------")
        print(f"网站：{url}")
        print(f"文件：{filename}")
        print("----------------------------------------")

        try:
            html = fetch_page(url)

            print(f"网页大小：{len(html)} bytes")

            ipv6_list = extract_ipv6(html)

            print(f"提取 IPv6：{len(ipv6_list)}")

            if ipv6_list:
                for ip in ipv6_list:
                    print(f"  {ip}")

                update_file(
                    filename,
                    ipv6_list,
                    today
                )

                success += 1

            else:
                print("没有找到 IPv6")
                print("跳过该网站，不修改历史文件")

        except Exception as e:
            print(f"访问失败：{e}")
            print("跳过该网站，不修改历史文件")

    print()
    print("========================================")
    print(f"成功更新：{success}/{len(SOURCES)}")
    print("========================================")


if __name__ == "__main__":
    main()
