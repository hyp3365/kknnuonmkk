import ipaddress
import re
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
SOURCES = {
    "https://www.wetest.vip/page/cloudfront/total_v6.html": "CloudFront-ipv6.txt",
    "https://www.wetest.vip/page/cloudflare/total_v6.html": "CloudFlare-ipv6.txt",
}
IPV6_PATTERN = re.compile(r'(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){2,7}(?:[0-9A-Fa-f]{1,4})?(?![0-9A-Fa-f:])')
def fetch_page(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        }
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read()
    return data.decode("utf-8", errors="ignore")
def extract_ipv6(html):
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
    path = Path(filename)
    cutoff = today - timedelta(days=29)
    old_lines = []
    if path.exists():
        try:
            old_lines = path.read_text(encoding="utf-8").splitlines()
        except Exception as e:
            print(f"读取 {filename} 失败：{e}")
            return False
    new_lines = []
    for line in old_lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        date_text = parts[0]
        try:
            record_date = datetime.strptime(date_text, "%Y-%m-%d").date()
        except ValueError:
            continue
        if record_date >= cutoff:
            new_lines.append(line)
    for ip in ipv6_list:
        new_lines.append(f"{today} {ip}")
    try:
        if new_lines:
            content = "\n".join(new_lines) + "\n"
        else:
            content = ""
        path.write_text(content, encoding="utf-8")
    except Exception as e:
        print(f"写入 {filename} 失败：{e}")
        return False
    print()
    print(f"文件：{filename}")
    print(f"今天新增：{len(ipv6_list)}")
    print(f"当前记录：{len(new_lines)}")
    print(f"文件位置：{path.resolve()}")
    return True
def process_source(url, filename, today):
    print()
    print("=" * 70)
    print(f"网站：{url}")
    print(f"保存：{filename}")
    print("=" * 70)
    try:
        html = fetch_page(url)
        print(f"网页大小：{len(html)} bytes")
        ipv6_list = extract_ipv6(html)
        print(f"提取 IPv6：{len(ipv6_list)}")
        if not ipv6_list:
            print("没有找到 IPv6，跳过本次更新")
            return False
        print()
        print("本次获取：")
        for index, ip in enumerate(ipv6_list, start=1):
            print(f"{index:02d}. {ip}")
        return update_file(filename, ipv6_list, today)
    except Exception as e:
        print()
        print(f"访问失败：{e}")
        print("跳过本次更新，不修改历史数据")
        return False
def main():
    beijing_timezone = timezone(timedelta(hours=8))
    today = datetime.now(beijing_timezone).date()
    print()
    print("=" * 70)
    print("IPv6 自动采集程序")
    print("=" * 70)
    print(f"北京时间日期：{today}")
    print(f"当前目录：{Path.cwd()}")
    print(f"Python：{__import__('sys').version}")
    print("=" * 70)
    success_count = 0
    total_count = len(SOURCES)
    for url, filename in SOURCES.items():
        result = process_source(url, filename, today)
        if result:
            success_count += 1
    print()
    print("=" * 70)
    print(f"更新完成：{success_count}/{total_count}")
    print("=" * 70)
    print()
    for filename in SOURCES.values():
        path = Path(filename)
        if path.exists():
            try:
                line_count = len(path.read_text(encoding="utf-8").splitlines())
            except Exception:
                line_count = 0
            print(f"{filename}: {line_count} 条记录")
        else:
            print(f"{filename}: 文件不存在")
if __name__ == "__main__":
    main()
