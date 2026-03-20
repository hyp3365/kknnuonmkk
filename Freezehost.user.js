// ==UserScript==
// @name         Freezehost 极致拟人稳定版 v28.0
// @namespace    http://tampermonkey.net/
// @version      28.0
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

    function mouseClick(el) {
        if (!el) return;
        const rect = el.getBoundingClientRect();
        const x = rect.left + 5 + Math.random() * (rect.width - 10);
        const y = rect.top + 5 + Math.random() * (rect.height - 10);
        ['mouseenter', 'mousedown', 'mouseup', 'click'].forEach(t => {
            el.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
        });
    }

    function handleAds() {
        const closeSelectors = [
            'button[aria-label*="Close"]', 
            '#dismiss-button', 
            'div[role="button"][aria-label*="close"]',
            '.close-button',
            'span[class*="close"]'
        ];
        
        for (let sel of closeSelectors) {
            const btn = document.querySelector(sel);
            if (btn && btn.offsetWidth > 0) {
                mouseClick(btn);
                return true;
            }
        }

        const bText = document.body.innerText.toUpperCase();
        if (bText.includes("UNLOCK MORE CONTENT") || bText.includes("VIEW A SHORT AD")) {
            const adBtn = Array.from(document.querySelectorAll('*'))
                               .find(e => e.innerText && e.innerText.toUpperCase().includes("VIEW A SHORT AD") && e.offsetWidth > 0);
            if (adBtn) {
                busyLock = true;
                mouseClick(adBtn);
                setTimeout(() => { location.reload(); }, 60000);
                return true;
            }
        }
        return false;
    }

    function process() {
        if (busyLock) return;

        if (handleAds()) return;

        const bodyText = document.body.innerText;
        const actionDelay = Math.floor(Math.random() * 2001) + 3000;
        const checkInterval = Math.floor(Math.random() * 5001) + 10000;

        if (scrollCounter >= nextScrollAt) {
            const dist = (Math.floor(Math.random() * 41) + 10) * (Math.random() > 0.5 ? 1 : -1);
            window.scrollBy({ top: dist, behavior: 'smooth' });
            setTimeout(() => { window.scrollBy({ top: -dist, behavior: 'smooth' }); }, 600);
            scrollCounter = 0;
            nextScrollAt = Math.floor(Math.random() * 6) + 5;
        } else {
            scrollCounter++;
        }

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
                    mouseClick(afkBtn);
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
