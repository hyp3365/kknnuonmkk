import subprocess
import time

# 启动节点搭建脚本 修改脚本名字
subprocess.Popen(["python3", "a.py"])

# 启动vps向Python容器推送运行信息脚本
subprocess.Popen(["python3", "Python.py"])

print("所有程序已启动")
while True:
    time.sleep(1)
  
