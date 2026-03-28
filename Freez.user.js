// ==UserScript==
// @name         Freezehost 智能挂机助手 (稳定增强版)
// @namespace    http://tampermonkey.net/
// @version      6.1
// @description  监控倒计时状态，模拟人工操作，优化卡顿重连逻辑
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    // --- 配置项 ---
    const CONFIG = {
        checkInterval: 12000,        // 检查间隔 (约12秒)
        stagnantLimit: 5,            // 连续检测到卡顿几次后刷新 (5 * 12s = 60s)
        keywords: ["Start AFK Session", "开始挂机会话", "Start New Session", "开始新会话", "Claim"],
        logPrefix: "【挂机助手】"
    };

    let state = {
        lastTime: "",
        stagnantCount: 0
    };

    // 辅助函数：随机延迟
    const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms + Math.random() * 2000));

    /**
     * 执行点击动作
     */
    async function tryClickButton() {
        const buttons = Array.from(document.querySelectorAll('button, a, .btn'));
        const targetBtn = buttons.find(b => 
            CONFIG.keywords.some(k => b.innerText.trim().includes(k)) && b.offsetParent !== null
        );

        if (targetBtn) {
            console.log(`${CONFIG.logPrefix}发现目标按钮: "${targetBtn.innerText.trim()}"，准备执行...`);
            await sleep(3000); // 模拟人类思考时间
            targetBtn.click();
            return true;
        }
        return false;
    }

    /**
     * 核心监控逻辑
     */
    async function monitor() {
        const bodyText = document.body.innerText;
        // 匹配 00:00 格式的倒计时
        const timeMatch = bodyText.match(/(\d{1,2}):(\d{2})/);

        if (timeMatch) {
            const currentTime = timeMatch[0];
            
            if (currentTime === state.lastTime) {
                state.stagnantCount++;
                console.warn(`${CONFIG.logPrefix}检测到时间停滞 (${state.stagnantCount}/${CONFIG.stagnantLimit})`);
            } else {
                state.stagnantCount = 0; // 正常变动，重置计数
                console.log(`${CONFIG.logPrefix}挂机中，剩余时间: ${currentTime}`);
            }

            state.lastTime = currentTime;

            // 如果卡死超过阈值，刷新页面
            if (state.stagnantCount >= CONFIG.stagnantLimit) {
                console.error(`${CONFIG.logPrefix}长时间无反应，尝试刷新页面恢复...`);
                location.reload();
            }

        } else {
            // 页面上找不到时间，尝试寻找开始按钮
            const clicked = await tryClickButton();
            
            if (!clicked) {
                // 既没时间也没按钮，可能是页面加载失败或被拦截
                console.warn(`${CONFIG.logPrefix}未匹配到倒计时或按钮，观察中...`);
                state.stagnantCount++;
                
                if (state.stagnantCount > 3) {
                    await sleep(2000);
                    location.reload();
                }
            } else {
                state.stagnantCount = 0; // 点击成功后重置
            }
        }
    }

    // --- 初始化运行 ---
    console.log(`${CONFIG.logPrefix}脚本已启动，正在守护您的挂机会话...`);

    // 1. 定时检查逻辑
    setInterval(monitor, CONFIG.checkInterval);

    // 2. 模拟人工保活：随机微滚动
    setInterval(() => {
        if (Math.random() > 0.5) {
            window.scrollBy({ top: 5, behavior: 'smooth' });
            setTimeout(() => window.scrollBy({ top: -5, behavior: 'smooth' }), 800);
        }
    }, 45000);

    // 3. 页面初次加载检测
    window.addEventListener('load', () => {
        setTimeout(monitor, 5000);
    });

})();
