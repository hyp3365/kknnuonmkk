// ==UserScript==
// @name         Freezehost 全能挂机助手 v15.0
// @namespace    http://tampermonkey.net/
// @version      15.0
// @description  1.检测时间卡死/归零刷新 2.自动点X关闭广告 3.10-30秒随机检测一次
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lastCountdown = "";
    let stagnantCount = 0;

    // --- 核心功能 1: 关闭广告 ---
    function closeAds() {
        // 寻找常见的关闭/叉号关键词
        const closeLabels = ["CLOSE", "DISMISS", "关闭", "×", "X", "SKIP"];
        const elements = document.querySelectorAll('button, a, div, span, i');

        elements.forEach(el => {
            const text = el.innerText.trim().toUpperCase();
            const style = window.getComputedStyle(el);
            
            // 识别小尺寸的叉号按钮或带有关闭字样的元素
            const isVisible = el.offsetWidth > 0 && style.display !== 'none' && style.visibility !== 'hidden';
            if (isVisible && (closeLabels.includes(text) || (el.offsetWidth < 50 && (text === "X" || text === "×")))) {
                // 只有层级较高的（弹窗）才点击
                if (parseInt(style.zIndex) > 5 || style.position === 'fixed') {
                    console.log("【清理】发现遮挡广告，执行点击关闭...");
                    el.click();
                    el.dispatchEvent(new MouseEvent('click', {bubbles: true}));
                }
            }
        });
        
        // 专项处理 Google 弹窗按钮
        const googleDismiss = document.querySelector('#dismiss-button');
        if (googleDismiss) googleDismiss.click();
    }

    // --- 核心功能 2: 点击挂机按钮 ---
    function clickAFK() {
        const btns = document.querySelectorAll('button, a, .btn');
        for (let btn of btns) {
            const txt = btn.innerText.toUpperCase();
            if (txt.includes("AFK") || txt.includes("START")) {
                if (btn.offsetWidth > 0 && !btn.disabled) {
                    console.log("【挂机】点击 Start AFK Session 按钮");
                    btn.click();
                }
            }
        }
    }

    // --- 核心功能 3: 检测时间状态 ---
    function monitorStatus() {
        console.log("【监控】正在扫描页面状态...");
        closeAds(); // 每次检查先清广告
        
        const bodyText = document.body.innerText;
        
        // 1. 检测 Session 是否归零 (0:00)
        if (bodyText.includes("Session Time Remaining") && bodyText.includes("0:00")) {
            console.log("【异常】检测到时间归零，刷新网页...");
            location.reload();
            return;
        }

        // 2. 检测 Countdown 是否卡住 (例如一直停在 1 seconds)
        const timeMatch = bodyText.match(/(\d+)\s+seconds/);
        if (timeMatch) {
            const currentC = timeMatch[0];
            if (currentC === lastCountdown) {
                stagnantCount++;
            } else {
                stagnantCount = 0; 
            }
            lastCountdown = currentC;

            // 如果连续 3 次检测（约 30-90秒）时间都没变，判定为卡死
            if (stagnantCount >= 3) {
                console.log("【异常】检测到倒计时卡住，刷新网页...");
                location.reload();
                return;
            }
        } else {
            // 如果页面上连 seconds 都不显示了，说明没在挂机
            clickAFK();
        }
    }

    // --- 核心功能 4: 随机间隔调度 ---
    function scheduler() {
        monitorStatus();
        
        // 生成 10 秒到 30 秒之间的随机数
        const nextRun = Math.floor(Math.random() * (30000 - 10000 + 1)) + 10000;
        console.log(`【调度】下次检测将在 ${(nextRun/1000).toFixed(1)} 秒后...`);
        setTimeout(scheduler, nextRun);
    }

    // 启动脚本
    console.log("【守护】v15.0 启动成功，随机检测模式开启");
    setTimeout(scheduler, 5000);

    // 每 20 分钟强制大刷新一次，防止网页内存溢出导致浏览器崩溃
    setTimeout(() => location.reload(), 1200000 + Math.random() * 60000);

})();
