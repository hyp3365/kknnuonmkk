// ==UserScript==
// @name         Freezehost 极致拟人稳定版 v35.0
// @namespace    http://tampermonkey.net/
// @version      35.0
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

    // 执行左右两侧空白区域（间隙中点）的点击
    function clickSideGaps() {
        if (clickingLock) return;
        clickingLock = true;

        // 核心：直接寻找广告特征元素，不再依赖网址检测
        const adModal = document.querySelector('ins.adsbygoogle iframe') || 
                        document.querySelector('div[role="dialog"]') ||
                        document.querySelector('.google-vignette-container') ||
                        document.querySelector('#google_ads_iframe_');

        if (adModal || window.location.href.includes("#goog")) {
            let leftGapCenter, rightGapCenter, targetY;

            if (adModal && adModal.offsetWidth > 0) {
                const rect = adModal.getBoundingClientRect();
                // 点击位置：弹窗边缘到页面边缘的中心点
                leftGapCenter = rect.left / 2;
                rightGapCenter = rect.right + (window.innerWidth - rect.right) / 2;
                targetY = rect.top + (rect.height / 2);
                console.log("【特征识别】发现广告实体，点击两侧空白带中点...");
            } else {
                // 兜底：如果网址变了但找不到实体，点击预估位置
                leftGapCenter = window.innerWidth * 0.1;
                rightGapCenter = window.innerWidth * 0.9;
                targetY = window.innerHeight * 0.5;
                console.log("【网址触发】未发现实体，点击默认边缘位置...");
            }
            
            fastClick(leftGapCenter, targetY);
            setTimeout(() => { fastClick(rightGapCenter, targetY); }, 200);
        }

        setTimeout(() => { clickingLock = false; }, 1000);
    }

    function process() {
        if (busyLock) return;

        // 1. 每轮检测都尝试清理广告（不再依赖 URL 变化通知）
        clickSideGaps();

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

        // 2. 核心时间检测（3次卡死刷新）
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

    // 启动检查
    setTimeout(process, 5000);
})();
