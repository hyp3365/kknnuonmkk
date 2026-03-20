// ==UserScript==
// @name         Freezehost  v19.0
// @namespace    http://tampermonkey.net/
// @version      19.0
// @description  Randomized delays and refined freeze detection for human-like behavior.
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lastT = "";
    let sCount = 0;
    let isAct = false;

    function hC(e) {
        if (!e) return;
        const r = e.getBoundingClientRect();
        const x = r.left + 5 + Math.random() * (r.width - 10);
        const y = r.top + 5 + Math.random() * (r.height - 10);
        ['mouseenter', 'mousedown', 'mouseup', 'click'].forEach(t => {
            e.dispatchEvent(new MouseEvent(t, {
                bubbles: true,
                cancelable: true,
                view: window,
                clientX: x,
                clientY: y
            }));
        });
    }

    function cA() {
        const k = ["CLOSE", "DISMISS", "关闭", "×", "X"];
        document.querySelectorAll('button, a, div, span, i').forEach(e => {
            const t = e.innerText.trim().toUpperCase();
            const s = window.getComputedStyle(e);
            if (e.offsetWidth > 0 && e.offsetWidth < 90 && (k.includes(t) || (e.offsetWidth < 40 && (t === "X" || t === "×")))) {
                if (parseInt(s.zIndex) > 10 || s.position === 'fixed') {
                    hC(e);
                }
            }
        });
    }

    function run() {
        if (isAct) return;

        cA();

        const b = document.body.innerText;
        const actD = Math.floor(Math.random() * 20001) + 10000;
        const nxtD = Math.floor(Math.random() * 15001) + 15000;

        if (b.includes("Session Time Remaining") && b.includes("0:00")) {
            isAct = true;
            setTimeout(() => {
                location.reload();
            }, actD);
            return;
        }

        const m = b.match(/(\d+)\s+seconds/);
        if (m) {
            if (m[0] === lastT) {
                sCount++;
            } else {
                sCount = 0;
                lastT = m[0];
            }

            if (sCount >= 2) {
                isAct = true;
                setTimeout(() => {
                    location.reload();
                }, actD);
                return;
            }
        } else {
            const btn = Array.from(document.querySelectorAll('button, a, .btn, [role="button"]'))
                             .find(el => el.innerText.toUpperCase().includes("AFK") && el.offsetWidth > 0);
            if (btn) {
                isAct = true;
                setTimeout(() => {
                    hC(btn);
                    isAct = false;
                    setTimeout(run, nxtD);
                }, actD);
                return;
            }
        }

        setTimeout(run, nxtD);
    }

    const initD = Math.floor(Math.random() * 20001) + 10000;
    setTimeout(run, initD);

})();
