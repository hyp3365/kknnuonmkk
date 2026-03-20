// ==UserScript==
// @name         Freezehost 专用挂机 (锁定AFK按钮版)
// @namespace    http://tampermonkey.net/
// @version      11.0
// @description  每20分钟+随机30-90秒强刷，精准点击 Start AFK Session 按钮
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    // --- 核心配置 ---
    const baseMinutes = 20;            // 20分钟
    const minRandomSec = 30;           // 最少加30秒
    const maxRandomSec = 90;           // 最多加90秒
    const checkInterval = 5000;        // 每5秒扫一次按钮
    // ----------------

    // 1. 计算本次刷新的总时间
    const randomExtra = Math.floor(Math.random() * (maxRandomSec - minRandomSec + 1)) + minRandomSec;
    const totalWaitMs = (baseMinutes * 60 + randomExtra) * 1000;

    console.log(`【助手】挂机守护中...`);
    console.log(`【助手】下次刷新时间：${(totalWaitMs/1000/60).toFixed(2)} 分钟后`);

    // 设置定时刷新
    setTimeout(() => {
        console.log("【助手】时间到，强制刷新页面重启会话...");
        location.reload();
    }, totalWaitMs);

    // 2. 精准点击 AFK 按钮逻辑
    function clickAFKButton() {
        // 寻找所有按钮、链接和带按钮样式的元素
        const elements = document.querySelectorAll('button, a, .btn, [role="button"]');
        
        for (let el of elements) {
            const text = el.innerText.trim().toUpperCase();
            
            // 精准匹配包含 "AFK" 的按钮
            if (text.includes("AFK") || text.includes("START AFK")) {
                // 确保按钮是可见的且没有被禁用
                if (el.offsetWidth > 0 && el.offsetHeight > 0 && !el.disabled) {
                    console.log("【助手】成功锁定 AFK 按钮，执行点击！");
                    el.click();
                    
                    // 额外触发一次 MouseEvent，防止页面脚本拦截原生 click
                    el.dispatchEvent(new MouseEvent('click', {
                        bubbles: true, 
                        cancelable: true, 
                        view: window
                    }));
                    break; 
                }
            }
        }
    }

    // 每 5 秒执行一次检测，确保页面加载完后能立刻点上
    setInterval(clickAFKButton, checkInterval);

    // 3. 页面活跃保活
    setInterval(() => {
        window.scrollBy(0, 1);
        setTimeout(() => window.scrollBy(0, -1), 100);
    }, 30000);

})();
