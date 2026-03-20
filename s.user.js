// ==UserScript==
// @name         Freezehost 智能挂机助手 (优化防封版)
// @namespace    http://tampermonkey.net/
// @version      6.1
// @description  监控倒计时状态，加入随机延迟模拟真实用户，防封优化
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lastCountdownValue = "";
    let stagnantCount = 0;

    function monitorAFK() {
        const bodyText = document.body.innerText;
        // 匹配 00:00 格式
        const countdownMatch = bodyText.match(/(\d{1,2}):(\d{2})/);

        if (countdownMatch) {
            const currentCountdown = countdownMatch[0];
            
            // 检查是否卡住
            if (currentCountdown === lastCountdownValue) {
                stagnantCount++;
            } else {
                stagnantCount = 0; 
            }
            lastCountdownValue = currentCountdown;

            // 卡顿超过 3 次检查（约 30-50秒）则刷新
            if (stagnantCount > 3) { 
                console.log("【监控】检测到卡顿，准备刷新...");
                location.reload();
            }
        } else {
            // 查找开始按钮
            const keywords = ["Start AFK Session", "开始挂机会话", "Start New Session", "开始新会话"];
            const buttons = Array.from(document.querySelectorAll('button, a'));
            const startBtn = buttons.find(b => keywords.some(k => b.innerText.includes(k)));

            if (startBtn) {
                // 模拟真实用户：随机等待 5-10 秒再点
                const delay = Math.floor(Math.random() * 5000) + 5000;
                console.log(`【监控】发现按钮，将在 ${delay/1000} 秒后模拟点击...`);
                setTimeout(() => {
                    startBtn.dispatchEvent(new MouseEvent('click', {
                        view: window,
                        bubbles: true,
                        cancelable: true
                    }));
                }, delay);
            }
        }

        // 核心优化：每次检查完后，随机设定下次检查的时间 (8-15秒之间)
        let nextCheck = Math.floor(Math.random() * 7000) + 8000;
        setTimeout(monitorAFK, nextCheck);
    }

    // 第一次启动
    setTimeout(monitorAFK, 5000);

    // 模拟微小的页面滚动保活
    setInterval(() => {
        window.scrollBy(0, Math.random() > 0.5 ? 1 : -1);
    }, 30000);

    console.log("【监控】优化版已启动。");
})();

