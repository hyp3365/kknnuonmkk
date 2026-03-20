// ==UserScript==
// @name         Freezehost 挂机 (模拟点击关闭广告版)
// @namespace    http://tampermonkey.net/
// @version      13.0
// @description  每20分钟+随机30-90秒刷新，先模拟点击关闭所有广告，再点AFK
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    // --- 配置 ---
    const baseMinutes = 20;
    const minRandomSec = 30;
    const maxRandomSec = 90;
    const scanInterval = 5000; // 每5秒扫一遍
    // -----------

    // 1. 刷新逻辑
    const randomExtra = Math.floor(Math.random() * (maxRandomSec - minRandomSec + 1)) + minRandomSec;
    const totalWaitMs = (baseMinutes * 60 + randomExtra) * 1000;

    console.log(`【守护】v13.0 启动。将在 ${(totalWaitMs/1000/60).toFixed(2)} 分钟后重置页面。`);

    setTimeout(() => {
        console.log("【守护】定时刷新中...");
        location.reload();
    }, totalWaitMs);

    // 2. 模拟点击关闭广告
    function closeAllAds() {
        // 寻找所有可能的关闭按钮特征
        const closeKeywords = ["CLOSE", "DISMISS", "关闭", "×", "X"];
        const allElements = document.querySelectorAll('button, a, div, span, i');

        allElements.forEach(el => {
            // 如果元素很小（可能是个X图标）或者包含关闭字样
            const text = el.innerText.trim().toUpperCase();
            const isSmall = el.offsetWidth > 0 && el.offsetWidth < 50; // 宽度很小的可能是叉号
            
            if (closeKeywords.includes(text) || (isSmall && (text === "X" || text === "×"))) {
                // 确保它在最上层 (zIndex 比较高)
                const zIndex = window.getComputedStyle(el).zIndex;
                if (zIndex > 10 || text === "CLOSE") {
                    console.log("【清理】发现广告关闭按钮，尝试点击...");
                    el.click();
                }
            }
        });
        
        // 专门对付 Google 这种 iframe 里的关闭按钮（如果有权限的话）
        const dismissBtn = document.querySelector('#dismiss-button');
        if (dismissBtn) dismissBtn.click();
    }

    // 3. 核心挂机点击逻辑
    function mainTask() {
        // 先点广告关闭按钮
        closeAllAds();

        // 延迟 1 秒再点 AFK，给广告消失留一点时间
        setTimeout(() => {
            const btns = document.querySelectorAll('button, a, .btn');
            for (let btn of btns) {
                const btnText = btn.innerText.toUpperCase();
                if (btnText.includes("AFK") || btnText.includes("START")) {
                    if (btn.offsetWidth > 0 && !btn.disabled) {
                        console.log("【挂机】执行点击 Start AFK Session");
                        btn.click();
                        btn.dispatchEvent(new MouseEvent('click', {bubbles: true}));
                        break;
                    }
                }
            }
        }, 1000);
    }

    // 每 5 秒巡检一次环境
    setInterval(mainTask, scanInterval);

    // 4. 防休眠滚动
    setInterval(() => window.scrollBy(0, 1), 30000);

})();
