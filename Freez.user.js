// ==UserScript==
// @name         Freezehost 智能挂机 - 倒计时监控版
// @namespace    http://tampermonkey.net/
// @version      11.0
// @description  监控倒计时状态，仅在结束或卡死时触发，支持 Discord 自动跳转回正轨
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    console.log("【挂机助手】监控已启动。");

    // 产生随机数
    const getRandom = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

    function checkAFKStatus() {
        const bodyText = document.body.innerText;
        
        // 1. 查找倒计时（格式如 18:09）
        const timerMatch = bodyText.match(/(\d{1,2}):(\d{2})/);
        
        if (timerMatch) {
            const timeLeft = timerMatch[0];
            // 如果倒计时在跑（不是 00:00），就什么都不做
            if (timeLeft !== "00:00" && timeLeft !== "0:00") {
                console.log("【助手】挂机进行中，剩余时间: " + timeLeft);
                return; 
            }
        }

        // 2. 如果没发现倒计时，或者倒计时是 00:00，说明需要启动
        console.log("【助手】未检测到运行中的倒计时，准备寻找按钮...");

        const allButtons = Array.from(document.querySelectorAll('button, a, div[role="button"]'));
        
        // 优先处理广告验证弹窗 (View a short ad)
        const adBtn = allButtons.find(b => b.innerText.includes('View a short ad') || b.innerText.includes('Unlock'));
        if (adBtn && adBtn.offsetParent !== null) {
            console.log("【助手】检测到广告验证弹窗，随机延迟后点击...");
            setTimeout(() => adBtn.click(), getRandom(3000, 6000));
            return;
        }

        // 处理开始/重启按钮
        const startKeywords = ["Start New Session", "开始新会话", "Start AFK Session", "开始挂机"];
        const startBtn = allButtons.find(b => startKeywords.some(k => b.innerText.includes(k)));

        if (startBtn && startBtn.offsetParent !== null) {
            console.log("【助手】发现启动按钮，准备执行点击...");
            setTimeout(() => {
                startBtn.click();
                console.log("【助手】点击已发送。");
            }, getRandom(4000, 8000));
        } else {
            // 3. 兜底逻辑：既没倒计时也没按钮，或者显示“Session Complete”
            if (bodyText.includes("Session Complete") || bodyText.includes("Session ended")) {
                console.log("【助手】检测到会话已彻底结束，尝试刷新页面重置状态...");
                location.href = "https://free.freezehost.pro/earn";
            }
        }
    }

    // 设置扫描频率为 20 秒一次，降低被发现的概率
    setInterval(checkAFKStatus, 20000);

    // 初始延迟启动
    setTimeout(checkAFKStatus, 5000);

    // 每 2 分钟模拟一次微小的页面滚动，防止标签页被浏览器“挂起”
    setInterval(() => {
        window.scrollBy(0, 1);
        setTimeout(() => window.scrollBy(0, -1), 200);
    }, 120000);

})();
