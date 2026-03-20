// ==UserScript==
// @name         Freezehost 极致拟人稳定版 v37.0
// @namespace    http://tampermonkey.net/
// @version      37.0
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lastTimeText = "";
    let freezeCounter = 0;
    let busyLock = false;
    let scrollCounter = 0;
    let nextScrollAt = Math.floor(Math.random() * 6) + 5;

    // 模拟点击函数：在指定位置点 1 次（左右各点一次）
    function singleClick(x, y) {
        const events = ['mouseenter', 'mousedown', 'mouseup', 'click'];
        const evObj = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y };
        events.forEach(type => {
            document.documentElement.dispatchEvent(new MouseEvent(type, evObj));
        });
    }

    // 执行你要求的：网页中间到边缘的左右点击
    function clickGaps() {
        // 计算点击位置：网页左边缘到网页中心的中间点，以及网页中心到右边缘的中间点
        const leftTargetX = window.innerWidth * 0.25;  // 左侧 1/4 处
        const rightTargetX = window.innerWidth * 0.75; // 右侧 3/4 处
        const targetY = window.innerHeight * 0.5;      // 垂直中心

        console.log(`【常规点击】执行边缘间隙点击: Left(${leftTargetX}), Right(${rightTargetX})`);
        
        // 立即点左边
        singleClick(leftTargetX, targetY);
        
        // 300毫秒后点右边
        setTimeout(() => {
            singleClick(rightTargetX, targetY);
        }, 300);
    }

    function process() {
        if (busyLock) return;

        // --- 第一步：不管广告在不在，先执行左右点击 ---
        clickGaps();

        // 稍微等待点击生效后再读取页面内容
        setTimeout(() => {
            const bodyText = document.body.innerText;
            const checkInterval = Math.floor(Math.random() * 5001) + 10000;

            // 随机滚动
            if (scrollCounter >= nextScrollAt) {
                const dist = (Math.floor(Math.random() * 41) + 10) * (Math.random() > 0.5 ? 1 : -1);
                window.scrollBy({ top: dist, behavior: 'smooth' });
                setTimeout(() => { window.scrollBy({ top: -dist, behavior: 'smooth' }); }, 600);
                scrollCounter = 0;
                nextScrollAt = Math.floor(Math.random() * 6) + 5;
            } else {
                scrollCounter++;
            }

            // --- 第二步：检测时间 ---
            const timeMatch = bodyText.match(/(\d{1,2}:\d{2})/) || bodyText.match(/(\d+)\s+seconds/i);
            
            if (timeMatch) {
                const currentTime = timeMatch[0];
                if (currentTime === lastTimeText) {
                    freezeCounter++;
                } else {
                    freezeCounter = 0;
                    lastTimeText = currentTime;
                }
                // 时间 3 次不动（约 45 秒）就刷新
                if (freezeCounter >= 3) {
                    location.reload();
                    return;
                }
            } else {
                // 如果读不到时间，可能是广告还没关掉或者网页卡了，尝试找 AFK 按钮
                const afkBtn = Array.from(document.querySelectorAll('button, a, .btn'))
                                    .find(el => el.innerText.toUpperCase().includes("AFK") && el.offsetWidth > 0);
                if (afkBtn) {
                    const r = afkBtn.getBoundingClientRect();
                    singleClick(r.left + r.width/2, r.top + r.height/2);
                    lastTimeText = "";
                    freezeCounter = 0;
                } else {
                    // 既没时间也没AFK，增加判定，连续3轮这样就强制刷新
                    freezeCounter++;
                    if (freezeCounter >= 3) {
                        location.reload();
                        return;
                    }
                }
            }

            setTimeout(process, checkInterval);
        }, 1000); // 给点击留 1 秒的反应时间
    }

    // 启动
    setTimeout(process, 3000);
})();
