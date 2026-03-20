// ==UserScript==
// @name         Freezehost 极致拟人稳定版 v20.0
// @namespace    http://tampermonkey.net/
// @version      20.0
// @description  Pure logic, no comments, strictly following user delay and detection rules.
// @author       Gemini
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lT = "";
    let sC = 0;
    let bL = false;

    function mC(e) {
        if (!e) return;
        const r = e.getBoundingClientRect();
        const x = r.left + r.width / 2 + (Math.random() - 0.5) * 10;
        const y = r.top + r.height / 2 + (Math.random() - 0.5) * 10;
        ['mouseenter', 'mousedown', 'mouseup', 'click'].forEach(t => {
            e.dispatchEvent(new MouseEvent(t, {
                bubbles: true, cancelable: true, view: window, clientX: x, clientY: y
            }));
        });
    }

    function fA() {
        const k = ["CLOSE", "DISMISS", "关闭", "×", "X"];
        document.querySelectorAll('button, a, div, span, i').forEach(e => {
            const t = e.innerText.trim().toUpperCase();
            if (e.offsetWidth > 0 && e.offsetWidth < 100 && k.includes(t)) {
                const s = window.getComputedStyle(e);
                if (parseInt(s.zIndex) > 10 || s.position === 'fixed') {
                    mC(e);
                }
            }
        });
    }

    function p() {
        if (bL) return;

        fA();

        const b = document.body.innerText;
        const aD = Math.floor(Math.random() * 20001) + 10000;
        const nD = Math.floor(Math.random() * 15001) + 15000;

        const iZ = /Session Time Remaining\s+0:00/i.test(b);
        if (iZ) {
            bL = true;
            setTimeout(() => { location.reload(); }, aD);
            return;
        }

        const mT = b.match(/(\d+)\s+seconds/i);
        if (mT) {
            const cT = mT[0];
            if (cT === lT) {
                sC++;
            } else {
                sC = 0;
                lT = cT;
            }

            if (sC >= 2) {
                bL = true;
                setTimeout(() => { location.reload(); }, aD);
                return;
            }
        } else {
            const btn = Array.from(document.querySelectorAll('button, a, .btn'))
                             .find(el => el.innerText.toUpperCase().includes("AFK") && el.offsetWidth > 0);
            if (btn) {
                bL = true;
                setTimeout(() => {
                    mC(btn);
                    bL = false;
                    setTimeout(p, nD);
                }, aD);
                return;
            }
        }

        setTimeout(p, nD);
    }

    const sD = Math.floor(Math.random() * 20001) + 10000;
    setTimeout(p, sD);

})();
