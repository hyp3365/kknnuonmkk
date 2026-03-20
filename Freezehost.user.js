// ==UserScript==
// @name         Freezehost 拟人化挂机助手 v16.0
// @namespace    http://tampermonkey.net/
// @version      16.0
// @description  增加随机坐标点击、点击延迟、随机滚动，模拟真实人工操作
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lastCountdown = "";
    let stagnantCount = 0;

    // --- 拟人化核心 1: 随机坐标点击 ---
    function humanClick(el) {
        if (!el) return;
        
        // 获取按钮的大小和位置
        const rect = el.getBoundingClientRect();
        
        // 生成按钮范围内的随机坐标 (避开边缘 5 像素)
        const x = rect.left + 5 + Math.random() * (rect.width - 10);
        const y = rect.top + 5 + Math.random() * (rect.height - 10);

        // 模拟鼠标移入 -> 按下 -> 弹起 -> 点击 的完整流程
        const events = ['mouseenter', 'mousedown', 'mouseup', 'click'];
        events.forEach(type => {
            el.dispatchEvent(new MouseEvent(type, {
                bubbles: true,
                cancelable: true,
                view: window,
                clientX: x,
                clientY: y
            }));
        });
        console.log(`【人工模拟】点击坐标: (${x.toFixed(0)}, ${y.toFixed(0)})`);
    }

    // --- 拟人化核心 2: 模拟点击前摇 (思考时间) ---
    function delayedAction(actionFn, minMs, maxMs) {
        const delay = Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
        setTimeout(actionFn, delay);
    }

    // --- 核心功能: 检查并处理 ---
    function performTask() {
        console.log("【监控】正在观察页面...");

        // 1. 关广告 (模拟看到广告后 1-3 秒点叉)
        const closeLabels = ["CLOSE", "DISMISS", "关闭", "×", "X"];
        const els = document.querySelectorAll('button, a, div, span');
        els.forEach(el => {
            const txt = el.innerText.trim().toUpperCase();
            const style = window.getComputedStyle(el);
            if (el.offsetWidth > 0 && style.display !== 'none' && (closeLabels.includes(txt) || (el.offsetWidth < 50 && (txt === "X" || txt === "×")))) {
                if (parseInt(style.zIndex) > 5) {
                    delayedAction(() => humanClick(el), 1000, 3000);
                }
            }
        });

        // 2. 时间检测逻辑
        const bodyText = document.body.innerText;
        if (bodyText.includes("Session Time Remaining") && bodyText.includes("0:00")) {
            console.log("【异常】检测到时间结束，准备刷新...");
            delayedAction(() => location.reload(), 2000, 5000);
            return;
        }

        const timeMatch = bodyText.match(/(\d+)\s+seconds/);
        if (timeMatch) {
            if (timeMatch[0] === lastCountdown) stagnantCount++;
            else stagnantCount = 0;
            lastCountdown = timeMatch[0];

            if (stagnantCount >= 3) {
                console.log("【异常】倒计时卡死，准备刷新...");
                delayedAction(() => location.reload(), 3000, 6000);
            }
        } else {
            // 3. 点挂机按钮 (模拟看到按钮后 2-5 秒再点)
            const btns = document.querySelectorAll('button, a, .btn');
            for (let btn of btns) {
                if (btn.innerText.toUpperCase().includes("AFK") && btn.offsetWidth > 0) {
                    delayedAction(() => humanClick(btn), 2000, 5000);
                    break;
                }
            }
        }
    }

    // --- 拟人化核心 3: 随机间隔扫描 ---
    function nextScan() {
        performTask();
        
        // 模拟真人不定期看一眼网页 (15秒 到 45秒 随机一次)
        const nextTime = Math.floor(Math.random() * (45000 - 15000 + 1)) + 15000;
        console.log(`【人工模拟】下次观察将在 ${(nextTime/1000).toFixed(1)} 秒后`);
        
        // 期间随机滚一下网页
        setTimeout(() => {
            const scrollAmt = (Math.random() - 0.5) * 200; // 随机上下滚一点
            window.scrollBy({ top: scrollAmt, behavior: 'smooth' });
        }, nextTime / 2);

        setTimeout(nextScan, nextTime);
    }

    // 启动
    console.log("【守护】v16.0 拟人化模式已开启。请确保开发者模式已打开。");
    setTimeout(nextScan, 5000);

})();
