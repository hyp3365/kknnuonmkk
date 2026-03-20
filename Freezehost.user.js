// ==UserScript==
// @name         Freezehost 极致拟人稳定版 v34.0
// @namespace    http://tampermonkey.net/
// @version      34.0
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
    let clickingLock = false;

    // 连点函数：在指定位置高速点 5 次
    function fastClick(x, y) {
        const events = ['mouseenter', 'mousedown', 'mouseup', 'click'];
        for (let i = 0; i < 5; i++) {
            setTimeout(() => {
                const curX = x + (Math.random() - 0.5) * 5;
                const curY = y + (Math.random() - 0.5) * 5;
                events.forEach(type => {
                    document.documentElement.dispatchEvent(new MouseEvent(type, {
                        bubbles: true, cancelable: true, view: window, clientX: curX, clientY: curY
                    }));
                });
            }, i * 20);
        }
    }

    // 执行左右两侧空白区域的点击
    function clickSideGaps() {
        if (clickingLock) return;
        clickingLock = true;

        // 尝试定位弹窗元素（Google插页广告通常带有这些特征）
        const adModal = document.querySelector('ins.adsbygoogle iframe') || 
                        document.querySelector('div[role="dialog"]') ||
                        document.querySelector('.google-vignette-container');

        let leftGapCenter, rightGapCenter, targetY;

        if (adModal) {
            const rect = adModal.getBoundingClientRect();
            // 左侧空隙中心 = 弹窗左边缘 / 2
            leftGapCenter = rect.left / 2;
            // 右侧空隙中心 = 弹窗右边缘 + (页面总宽 - 弹窗右边缘) / 2
            rightGapCenter = rect.right + (window.innerWidth - rect.right) / 2;
            // 点击高度取弹窗垂直中心
            targetY = rect.top + (rect.height / 2);
        } else {
            // 如果抓不到弹窗实体，预估弹窗占中间 60%，默认点左右 15% 处
            leftGapCenter = window.innerWidth * 0.15;
            rightGapCenter = window.innerWidth * 0.85;
            targetY = window.innerHeight * 0.5;
        }

        console.log(`【网址触发】点击左侧间隙: ${leftGapCenter.toFixed(0)}, 右侧间隙: ${rightGapCenter.toFixed(0)}`);
        
        fastClick(leftGapCenter, targetY); // 点左边
        setTimeout(() => {
            fastClick(rightGapCenter, targetY); // 200ms 后点右边
        }, 200);

        setTimeout(() => { clickingLock = false; }, 1000);
    }

    function process() {
        if (busyLock) return;

        // 1. 网址识别：发现 #goog 后缀，执行间隙点击
        if (window.location.href.includes("#goog")) {
            clickSideGaps();
        }

        const bodyText = document.body.innerText;
        const actionDelay = Math.floor(Math.random() * 2001) + 3000;
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

        // 2. 核心时间检测 (检测 3 次不变就刷新)
        const timeMatch = bodyText.match(/(\d{1,2}:\d{2})/) || bodyText.match(/(\d+)\s+seconds/i);
        if (timeMatch) {
            const currentTime = timeMatch[0];
            if (currentTime === lastTimeText) {
                freezeCounter++;
            } else {
                freezeCounter = 0;
                lastTimeText = currentTime;
            }
            if (freezeCounter >= 3) {
                busyLock = true;
                setTimeout(() => { location.reload(); }, actionDelay);
                return;
            }
        } else {
            const afkBtn = Array.from(document.querySelectorAll('button, a, .btn'))
                                .find(el => el.innerText.toUpperCase().includes("AFK") && el.offsetWidth > 0);
            if (afkBtn) {
                busyLock = true;
                setTimeout(() => {
                    const r = afkBtn.getBoundingClientRect();
                    const bx = r.left + r.width/2;
                    const by = r.top + r.height/2;
                    ['mouseenter', 'mousedown', 'mouseup', 'click'].forEach(t => {
                        afkBtn.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window, clientX: bx, clientY: by }));
                    });
                    busyLock = false;
                    lastTimeText = "";
                    freezeCounter = 0;
                    setTimeout(process, checkInterval);
                }, Math.floor(Math.random() * 5001) + 10000);
                return;
            }
        }
        setTimeout(process, checkInterval);
    }

    setTimeout(process, 5000);
})();
